"""OAuth 2.0 authorization server for MCP connector authentication.

Implements the MCP 2025-03-26 authorization spec so that Claude.ai,
Claude Desktop, and other MCP clients can authenticate users through
a standard OAuth flow instead of requiring static API keys.

Flow:
  1. Client calls /v1/mcp without auth → server returns 401 with
     WWW-Authenticate header pointing to protected resource metadata.
  2. Client discovers the authorization server via
     /.well-known/oauth-protected-resource and
     /.well-known/oauth-authorization-server.
  3. Client registers via /v1/oauth/register (DCR).
  4. User authorizes via /v1/oauth/authorize → enters API key or
     signs in → receives authorization code.
  5. Client exchanges code for token at /v1/oauth/token.
  6. Client calls /v1/mcp with Authorization: Bearer <token>.

The OAuth access token is a signed JWT that wraps the user's API key.
The MCP endpoint resolves the JWT to the API key and validates it
through the existing api_admin.validate_api_key() function.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import secrets
import time
import uuid
from dataclasses import dataclass
from typing import Any

from fastapi import APIRouter, Form, Query, Request, Response
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from pydantic import BaseModel

logger = logging.getLogger("fpds.oauth")

router = APIRouter(tags=["oauth"])

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_OAUTH_ISSUER = os.environ.get(
    "OAUTH_ISSUER",
    "https://analytics-api.kenosaconsulting.com",
)

# JWT signing secret — in production, set OAUTH_SIGNING_SECRET to a
# cryptographically random 32+ byte hex string. Falls back to a
# derived-from-db-password value for dev.
_JWT_SECRET = os.environ.get("OAUTH_SIGNING_SECRET", "")

_ACCESS_TOKEN_TTL = 3600 * 24 * 30  # 30 days
_AUTH_CODE_TTL = 300  # 5 minutes
_REFRESH_TOKEN_TTL = 3600 * 24 * 90  # 90 days

# Scopes
_SCOPE_FPDS = "fpds:read"
_SUPPORTED_SCOPES = [_SCOPE_FPDS, "offline_access"]


# ---------------------------------------------------------------------------
# In-memory stores (single-process; sufficient for Render single-instance)
# ---------------------------------------------------------------------------

# registered_clients[client_id] = {client_secret, client_name, redirect_uris, ...}
_registered_clients: dict[str, dict[str, Any]] = {}

# auth_codes[code] = {client_id, user_api_key, scope, redirect_uri, code_challenge, expires_at}
_auth_codes: dict[str, dict[str, Any]] = {}

# access_tokens[token] = {api_key, scope, client_id, expires_at}
_access_tokens: dict[str, dict[str, Any]] = {}

# refresh_tokens[token] = {api_key, scope, client_id, access_token}
_refresh_tokens: dict[str, dict[str, Any]] = {}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _base_url(request: Request) -> str:
    """Determine the canonical base URL for this deployment."""
    # Use forwarded headers from Render
    host = request.headers.get("X-Forwarded-Host") or request.headers.get("Host", "")
    proto = request.headers.get("X-Forwarded-Proto", "https")
    if host:
        return f"{proto}://{host}"
    return _OAUTH_ISSUER


def _jwt_secret() -> str:
    """Get the signing secret, deriving one if not configured."""
    global _JWT_SECRET
    if _JWT_SECRET:
        return _JWT_SECRET
    # Derive from DB password for dev convenience
    db_pass = os.environ.get("DB_PASS", "")
    if db_pass:
        _JWT_SECRET = hashlib.sha256(f"fpds-oauth-{db_pass}".encode()).hexdigest()
    else:
        _JWT_SECRET = hashlib.sha256(f"fpds-oauth-dev-{secrets.token_hex(16)}".encode()).hexdigest()
    return _JWT_SECRET


def _issue_access_token(api_key: str, scope: str, client_id: str) -> str:
    """Issue an opaque access token mapped to an API key."""
    token = f"fpds_at_{secrets.token_urlsafe(32)}"
    _access_tokens[token] = {
        "api_key": api_key,
        "scope": scope,
        "client_id": client_id,
        "expires_at": time.time() + _ACCESS_TOKEN_TTL,
    }
    return token


def _issue_refresh_token(api_key: str, scope: str, client_id: str) -> str:
    """Issue a refresh token."""
    token = f"fpds_rt_{secrets.token_urlsafe(32)}"
    _refresh_tokens[token] = {
        "api_key": api_key,
        "scope": scope,
        "client_id": client_id,
    }
    return token


def resolve_access_token(token: str) -> str | None:
    """Resolve an OAuth access token to the underlying API key.
    Returns None if the token is invalid or expired."""
    entry = _access_tokens.get(token)
    if not entry:
        return None
    if time.time() > entry["expires_at"]:
        _access_tokens.pop(token, None)
        return None
    return entry["api_key"]


def _cleanup_expired():
    """Remove expired auth codes and access tokens."""
    now = time.time()
    expired_codes = [k for k, v in _auth_codes.items() if now > v["expires_at"]]
    for k in expired_codes:
        _auth_codes.pop(k, None)
    expired_tokens = [k for k, v in _access_tokens.items() if now > v["expires_at"]]
    for k in expired_tokens:
        _access_tokens.pop(k, None)


# ---------------------------------------------------------------------------
# Well-known endpoints
# ---------------------------------------------------------------------------

@router.get("/.well-known/oauth-protected-resource")
def protected_resource_metadata(request: Request) -> dict[str, Any]:
    """RFC 9728 protected resource metadata.
    Tells MCP clients where to find the authorization server."""
    base = _base_url(request)
    return {
        "resource": f"{base}/v1/mcp",
        "authorization_servers": [f"{base}/v1/oauth"],
        "scopes_supported": _SUPPORTED_SCOPES,
        "bearer_methods_supported": ["header"],
        "resource_documentation": f"{base}/v1",
    }


@router.get("/.well-known/oauth-authorization-server")
def authorization_server_metadata(request: Request) -> dict[str, Any]:
    """RFC 8414 authorization server metadata.
    Tells MCP clients how to authenticate."""
    base = _base_url(request)
    return {
        "issuer": base,
        "authorization_endpoint": f"{base}/v1/oauth/authorize",
        "token_endpoint": f"{base}/v1/oauth/token",
        "registration_endpoint": f"{base}/v1/oauth/register",
        "revocation_endpoint": f"{base}/v1/oauth/revoke",
        "scopes_supported": _SUPPORTED_SCOPES,
        "response_types_supported": ["code"],
        "response_modes_supported": ["query"],
        "grant_types_supported": ["authorization_code", "refresh_token"],
        "token_endpoint_auth_methods_supported": ["client_secret_post", "none"],
        "code_challenge_methods_supported": ["S256"],
        "introspection_endpoint": f"{base}/v1/oauth/introspect",
        "revocation_endpoint_auth_methods_supported": ["client_secret_post"],
    }


# ---------------------------------------------------------------------------
# Dynamic Client Registration (DCR) — RFC 7591
# ---------------------------------------------------------------------------

class ClientRegistrationRequest(BaseModel):
    client_name: str = "MCP Client"
    redirect_uris: list[str] = []
    grant_types: list[str] = ["authorization_code", "refresh_token"]
    response_types: list[str] = ["code"]
    token_endpoint_auth_method: str = "client_secret_post"
    scope: str = "fpds:read offline_access"


@router.post("/v1/oauth/register")
def register_client(body: ClientRegistrationRequest, request: Request) -> JSONResponse:
    """Register a new OAuth client (Dynamic Client Registration)."""
    base = _base_url(request)
    client_id = f"fpds_client_{secrets.token_urlsafe(16)}"
    client_secret = f"fpds_secret_{secrets.token_urlsafe(32)}"

    # Validate redirect URIs — allow Claude's callback + localhost for dev
    valid_redirects = []
    for uri in body.redirect_uris:
        if uri.startswith("https://claude.ai/") or uri.startswith("http://localhost") or uri.startswith("http://127.0.0.1"):
            valid_redirects.append(uri)

    _registered_clients[client_id] = {
        "client_id": client_id,
        "client_secret": client_secret,
        "client_name": body.client_name,
        "redirect_uris": valid_redirects,
        "grant_types": body.grant_types,
        "token_endpoint_auth_method": body.token_endpoint_auth_method,
        "scope": body.scope,
        "created_at": int(time.time()),
    }

    logger.info("OAuth client registered: %s (%s)", body.client_name, client_id[:30])

    response_data = {
        "client_id": client_id,
        "client_secret": client_secret,
        "client_id_issued_at": int(time.time()),
        "client_name": body.client_name,
        "redirect_uris": valid_redirects,
        "grant_types": body.grant_types,
        "response_types": body.response_types,
        "token_endpoint_auth_method": body.token_endpoint_auth_method,
        "scope": body.scope,
    }

    return JSONResponse(content=response_data, status_code=201)


# ---------------------------------------------------------------------------
# Authorization endpoint
# ---------------------------------------------------------------------------

@router.get("/v1/oauth/authorize")
def authorize_get(
    request: Request,
    response_type: str = Query(),
    client_id: str = Query(),
    redirect_uri: str = Query(),
    code_challenge: str = Query(default=""),
    code_challenge_method: str = Query(default="S256"),
    scope: str = Query(default="fpds:read"),
    state: str = Query(default=""),
) -> HTMLResponse:
    """Display the authorization page where the user enters their API key."""
    # Validate client
    client = _registered_clients.get(client_id)
    if not client:
        return HTMLResponse("<h1>Error</h1><p>Unknown client.</p>", status_code=400)

    if redirect_uri not in client["redirect_uris"]:
        return HTMLResponse("<h1>Error</h1><p>Redirect URI not registered.</p>", status_code=400)

    if response_type != "code":
        return HTMLResponse("<h1>Error</h1><p>Only 'code' response type is supported.</p>", status_code=400)

    # Render a simple HTML form for API key entry
    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Authorize FPDS Analytics</title>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
               background: #0f172a; color: #e2e8f0; display: flex; justify-content: center;
               align-items: center; min-height: 100vh; margin: 0; }}
        .card {{ background: #1e293b; border-radius: 12px; padding: 2rem; max-width: 480px; width: 100%; box-shadow: 0 8px 32px rgba(0,0,0,0.3); }}
        h1 {{ color: #60a5fa; font-size: 1.5rem; margin: 0 0 0.5rem; }}
        p {{ color: #94a3b8; font-size: 0.9rem; line-height: 1.5; }}
        label {{ display: block; color: #cbd5e1; font-size: 0.85rem; margin: 1rem 0 0.25rem; }}
        input[type="password"], input[type="text"] {{ width: 100%; padding: 0.6rem; border: 1px solid #334155;
            border-radius: 6px; background: #0f172a; color: #e2e8f0; font-size: 0.9rem; box-sizing: border-box; }}
        input:focus {{ outline: none; border-color: #60a5fa; }}
        button {{ width: 100%; padding: 0.7rem; background: #3b82f6; color: white; border: none;
            border-radius: 6px; font-size: 1rem; font-weight: 600; cursor: pointer; margin-top: 1.5rem; }}
        button:hover {{ background: #2563eb; }}
        .footer {{ text-align: center; margin-top: 1rem; font-size: 0.75rem; color: #64748b; }}
        .error {{ color: #f87171; font-size: 0.85rem; margin-top: 0.5rem; display: none; }}
        .signup {{ text-align: center; margin-top: 1rem; }}
        .signup a {{ color: #60a5fa; text-decoration: none; font-size: 0.85rem; }}
        .signup a:hover {{ text-decoration: underline; }}
    </style>
</head>
<body>
    <div class="card">
        <h1>🔑 Authorize FPDS Analytics</h1>
        <p><strong>{client['client_name']}</strong> is requesting access to your FPDS Analytics account.</p>
        <form method="POST" action="/v1/oauth/authorize">
            <input type="hidden" name="client_id" value="{client_id}">
            <input type="hidden" name="redirect_uri" value="{redirect_uri}">
            <input type="hidden" name="code_challenge" value="{code_challenge}">
            <input type="hidden" name="code_challenge_method" value="{code_challenge_method}">
            <input type="hidden" name="scope" value="{scope}">
            <input type="hidden" name="state" value="{state}">
            <label for="api_key">Your FPDS Analytics API Key</label>
            <input type="password" name="api_key" id="api_key" placeholder="fpds_beta_..." autocomplete="off" required>
            <div class="error" id="error-msg"></div>
            <button type="submit">Authorize</button>
        </form>
        <div class="signup">
            <a href="https://analytics-api.kenosaconsulting.com/v1/keys/request" target="_blank">
                Don't have an API key? Request one free →
            </a>
        </div>
        <div class="footer">
            Kenosa Consulting · FPDS Analytics<br>
            Your API key is validated but never stored in plaintext.
        </div>
    </div>
</body>
</html>"""
    return HTMLResponse(content=html)


@router.post("/v1/oauth/authorize")
def authorize_post(
    request: Request,
    client_id: str = Form(),
    redirect_uri: str = Form(),
    code_challenge: str = Form(default=""),
    code_challenge_method: str = Form(default="S256"),
    scope: str = Form(default="fpds:read"),
    state: str = Form(default=""),
    api_key: str = Form(),
) -> RedirectResponse:
    """Process the authorization form — validate API key, issue auth code."""
    _cleanup_expired()

    # Validate client
    client = _registered_clients.get(client_id)
    if not client or redirect_uri not in client["redirect_uris"]:
        return RedirectResponse(url=f"{redirect_uri}?error=invalid_client", status_code=302)

    # Validate the API key against our existing auth backend
    from app.auth import _supabase_validate, _envvar_validate
    access = _supabase_validate(api_key)
    if not access:
        access = _envvar_validate(api_key)
    if not access or not access.is_authenticated:
        # Redirect back with error
        error_params = "error=access_denied&error_description=Invalid+API+key"
        if state:
            error_params += f"&state={state}"
        return RedirectResponse(url=f"{redirect_uri}?{error_params}", status_code=302)

    # Generate authorization code
    code = f"fpds_ac_{secrets.token_urlsafe(24)}"
    _auth_codes[code] = {
        "client_id": client_id,
        "api_key": api_key,
        "scope": scope,
        "redirect_uri": redirect_uri,
        "code_challenge": code_challenge,
        "code_challenge_method": code_challenge_method,
        "expires_at": time.time() + _AUTH_CODE_TTL,
    }

    # Redirect with code
    params = f"code={code}"
    if state:
        params += f"&state={state}"
    return RedirectResponse(url=f"{redirect_uri}?{params}", status_code=302)


# ---------------------------------------------------------------------------
# Token endpoint
# ---------------------------------------------------------------------------

@router.post("/v1/oauth/token")
def token_endpoint(
    request: Request,
    grant_type: str = Form(),
    code: str = Form(default=""),
    redirect_uri: str = Form(default=""),
    client_id: str = Form(default=""),
    client_secret: str = Form(default=""),
    code_verifier: str = Form(default=""),
    refresh_token: str = Form(default=""),
) -> JSONResponse:
    """OAuth 2.0 token endpoint — exchanges auth codes and refreshes tokens."""
    _cleanup_expired()

    # Authenticate client
    client = _registered_clients.get(client_id)
    if not client:
        return JSONResponse(
            status_code=401,
            content={"error": "invalid_client", "error_description": "Unknown client ID"},
        )

    # Validate client secret (skip for public clients with method "none")
    if client.get("token_endpoint_auth_method") != "none":
        if client.get("client_secret") != client_secret:
            return JSONResponse(
                status_code=401,
                content={"error": "invalid_client", "error_description": "Invalid client secret"},
            )

    if grant_type == "authorization_code":
        return _handle_authorization_code(code, redirect_uri, client_id, code_verifier, client)
    elif grant_type == "refresh_token":
        return _handle_refresh_token(refresh_token, client_id, client)
    else:
        return JSONResponse(
            status_code=400,
            content={"error": "unsupported_grant_type", "error_description": f"Grant type '{grant_type}' not supported"},
        )


def _handle_authorization_code(
    code: str, redirect_uri: str, client_id: str, code_verifier: str, client: dict
) -> JSONResponse:
    """Process authorization_code grant."""
    entry = _auth_codes.get(code)
    if not entry:
        return JSONResponse(
            status_code=400,
            content={"error": "invalid_grant", "error_description": "Invalid or expired authorization code"},
        )

    # Check expiry
    if time.time() > entry["expires_at"]:
        _auth_codes.pop(code, None)
        return JSONResponse(
            status_code=400,
            content={"error": "invalid_grant", "error_description": "Authorization code expired"},
        )

    # Verify client matches
    if entry["client_id"] != client_id:
        return JSONResponse(
            status_code=400,
            content={"error": "invalid_grant", "error_description": "Client ID mismatch"},
        )

    # Verify redirect URI matches
    if redirect_uri and entry["redirect_uri"] != redirect_uri:
        return JSONResponse(
            status_code=400,
            content={"error": "invalid_grant", "error_description": "Redirect URI mismatch"},
        )

    # Verify PKCE code_verifier against code_challenge
    if entry.get("code_challenge"):
        if not code_verifier:
            return JSONResponse(
                status_code=400,
                content={"error": "invalid_grant", "error_description": "Missing code_verifier (PKCE required)"},
            )
        import hashlib, base64
        expected = base64.urlsafe_b64encode(
            hashlib.sha256(code_verifier.encode()).digest()
        ).rstrip(b"=").decode()
        if expected != entry["code_challenge"]:
            return JSONResponse(
                status_code=400,
                content={"error": "invalid_grant", "error_description": "PKCE verification failed"},
            )

    # Consume the code
    api_key = entry["api_key"]
    scope = entry["scope"]
    _auth_codes.pop(code, None)

    # Issue tokens
    access_token = _issue_access_token(api_key, scope, client_id)
    token_response: dict[str, Any] = {
        "access_token": access_token,
        "token_type": "Bearer",
        "expires_in": _ACCESS_TOKEN_TTL,
        "scope": scope,
    }

    # Issue refresh token if offline_access scope was requested
    if "offline_access" in scope:
        refresh_tok = _issue_refresh_token(api_key, scope, client_id)
        token_response["refresh_token"] = refresh_tok

    return JSONResponse(content=token_response)


def _handle_refresh_token(refresh_token: str, client_id: str, client: dict) -> JSONResponse:
    """Process refresh_token grant."""
    entry = _refresh_tokens.get(refresh_token)
    if not entry:
        return JSONResponse(
            status_code=400,
            content={"error": "invalid_grant", "error_description": "Invalid refresh token"},
        )

    if entry["client_id"] != client_id:
        return JSONResponse(
            status_code=400,
            content={"error": "invalid_grant", "error_description": "Client ID mismatch"},
        )

    # Rotate: invalidate old refresh token
    api_key = entry["api_key"]
    scope = entry["scope"]
    _refresh_tokens.pop(refresh_token, None)

    # Issue new tokens
    access_token = _issue_access_token(api_key, scope, client_id)
    new_refresh = _issue_refresh_token(api_key, scope, client_id)

    return JSONResponse(content={
        "access_token": access_token,
        "token_type": "Bearer",
        "expires_in": _ACCESS_TOKEN_TTL,
        "scope": scope,
        "refresh_token": new_refresh,
    })


# ---------------------------------------------------------------------------
# Token introspection (for debugging)
# ---------------------------------------------------------------------------

@router.post("/v1/oauth/introspect")
def introspect_token(
    token: str = Form(),
    client_id: str = Form(default=""),
    client_secret: str = Form(default=""),
) -> JSONResponse:
    """RFC 7662 token introspection."""
    # Validate client
    client = _registered_clients.get(client_id)
    if not client or client.get("client_secret") != client_secret:
        return JSONResponse(content={"active": False})

    entry = _access_tokens.get(token)
    if not entry:
        return JSONResponse(content={"active": False})

    if time.time() > entry["expires_at"]:
        _access_tokens.pop(token, None)
        return JSONResponse(content={"active": False})

    return JSONResponse(content={
        "active": True,
        "scope": entry["scope"],
        "client_id": entry["client_id"],
        "exp": int(entry["expires_at"]),
        "token_type": "Bearer",
    })


# ---------------------------------------------------------------------------
# Token revocation
# ---------------------------------------------------------------------------

@router.post("/v1/oauth/revoke")
def revoke_token(
    token: str = Form(),
    client_id: str = Form(default=""),
    client_secret: str = Form(default=""),
) -> Response:
    """RFC 7009 token revocation."""
    client = _registered_clients.get(client_id)
    if not client or client.get("client_secret") != client_secret:
        return Response(status_code=401)

    _access_tokens.pop(token, None)
    _refresh_tokens.pop(token, None)
    return Response(status_code=200)
