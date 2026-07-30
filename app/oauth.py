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

The OAuth access token is an opaque string that maps to an FPDS API key.
Tokens are persisted in api_admin.oauth_* tables so they survive restarts.
Auth codes remain in-memory (5-min TTL, safe to lose on restart).
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import secrets
import threading
import time
import uuid
from contextlib import contextmanager
from typing import Any
from urllib.parse import urlparse

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

_ACCESS_TOKEN_TTL = 3600 * 24 * 30  # 30 days
_AUTH_CODE_TTL = 300  # 5 minutes
_REFRESH_TOKEN_TTL = 3600 * 24 * 90  # 90 days

# Scopes
_SCOPE_FPDS = "fpds:read"
_SUPPORTED_SCOPES = [_SCOPE_FPDS, "offline_access"]


# ---------------------------------------------------------------------------
# In-memory auth codes only (everything else is DB-persisted)
# ---------------------------------------------------------------------------

# auth_codes[code] = {client_id, api_key, scope, redirect_uri, code_challenge, expires_at}
_auth_codes: dict[str, dict[str, Any]] = {}
_lock = threading.Lock()


# ---------------------------------------------------------------------------
# DB helpers (lazy import to avoid circular deps at module load)
# ---------------------------------------------------------------------------

@contextmanager
def _oauth_db(read_only: bool = False):
    from app.db import db_cursor
    with db_cursor(read_only=read_only) as cur:
        yield cur


def _db_cleanup_expired():
    """Run DB cleanup of expired tokens (cheap — indexes are on expired rows only)."""
    try:
        with _oauth_db(read_only=False) as cur:
            cur.execute("SELECT api_admin.cleanup_expired_oauth_tokens()")
    except Exception:
        pass  # Non-critical; cron handles this too


# -- Clients ---------------------------------------------------------------

def _db_get_client(client_id: str) -> dict[str, Any] | None:
    try:
        with _oauth_db(read_only=True) as cur:
            cur.execute(
                "SELECT client_id, client_secret, client_name, redirect_uris, "
                "grant_types, token_endpoint_auth_method, scope "
                "FROM api_admin.oauth_clients WHERE client_id = %s",
                (client_id,),
            )
            row = cur.fetchone()
            if row:
                return {
                    "client_id": row["client_id"],
                    "client_secret": row["client_secret"],
                    "client_name": row["client_name"],
                    "redirect_uris": list(row["redirect_uris"]) if isinstance(row["redirect_uris"], list) else json.loads(str(row["redirect_uris"])),
                    "grant_types": row["grant_types"],
                    "token_endpoint_auth_method": row["token_endpoint_auth_method"],
                    "scope": row["scope"],
                }
    except Exception:
        logger.exception("DB client lookup failed")
    return None


def _db_register_client(client_id: str, client_secret: str, client_name: str,
                        redirect_uris: list[str], grant_types: list[str],
                        token_endpoint_auth_method: str, scope: str) -> bool:
    try:
        with _oauth_db(read_only=False) as cur:
            cur.execute(
                "INSERT INTO api_admin.oauth_clients "
                "(client_id, client_secret, client_name, redirect_uris, "
                "grant_types, token_endpoint_auth_method, scope) "
                "VALUES (%s, %s, %s, %s, %s, %s, %s) "
                "ON CONFLICT (client_id) DO UPDATE SET "
                "client_name = EXCLUDED.client_name, "
                "redirect_uris = EXCLUDED.redirect_uris, "
                "scope = EXCLUDED.scope, "
                "grant_types = EXCLUDED.grant_types",
                (client_id, client_secret, client_name, json.dumps(redirect_uris),
                 json.dumps(grant_types), token_endpoint_auth_method, scope),
            )
        return True
    except Exception:
        logger.exception("DB client registration failed")
        return False


# -- Access tokens ---------------------------------------------------------

def _db_issue_access_token(api_key: str, scope: str, client_id: str) -> str | None:
    token = f"fpds_at_{secrets.token_urlsafe(32)}"
    expires_at_ts = int(time.time()) + _ACCESS_TOKEN_TTL
    # Use ISO format for TIMESTAMPTZ
    from datetime import datetime, timezone, timedelta
    expires_dt = datetime.now(timezone.utc) + timedelta(seconds=_ACCESS_TOKEN_TTL)
    try:
        with _oauth_db(read_only=False) as cur:
            cur.execute(
                "INSERT INTO api_admin.oauth_access_tokens "
                "(token, api_key, client_id, scope, expires_at) "
                "VALUES (%s, %s, %s, %s, %s)",
                (token, api_key, client_id, scope, expires_dt.isoformat()),
            )
        _db_cleanup_expired()
        return token
    except Exception:
        logger.exception("DB access token insert failed")
        return None


def resolve_access_token(token: str) -> str | None:
    """Resolve an OAuth access token to the underlying API key.
    Returns None if the token is invalid or expired.
    This is the hot path — called on every MCP request with Bearer auth."""
    try:
        with _oauth_db(read_only=False) as cur:
            cur.execute(
                "DELETE FROM api_admin.oauth_access_tokens "
                "WHERE token = %s AND expires_at < now()",
                (token,),
            )
            cur.execute(
                "SELECT api_key FROM api_admin.oauth_access_tokens "
                "WHERE token = %s AND expires_at > now()",
                (token,),
            )
            row = cur.fetchone()
            if row:
                return row["api_key"]
    except Exception:
        logger.exception("DB access token resolve failed")
    return None


# -- Refresh tokens --------------------------------------------------------

def _db_issue_refresh_token(api_key: str, scope: str, client_id: str) -> str | None:
    token = f"fpds_rt_{secrets.token_urlsafe(32)}"
    from datetime import datetime, timezone, timedelta
    expires_dt = datetime.now(timezone.utc) + timedelta(seconds=_REFRESH_TOKEN_TTL)
    try:
        with _oauth_db(read_only=False) as cur:
            cur.execute(
                "INSERT INTO api_admin.oauth_refresh_tokens "
                "(token, access_token, api_key, client_id, scope, expires_at) "
                "VALUES (%s, %s, %s, %s, %s, %s)",
                (token, "", api_key, client_id, scope, expires_dt.isoformat()),
            )
        return token
    except Exception:
        logger.exception("DB refresh token insert failed")
        return None


def _db_rotate_refresh_token(old_token: str, api_key: str, scope: str, client_id: str) -> str | None:
    # Delete old, issue new
    try:
        with _oauth_db(read_only=False) as cur:
            cur.execute(
                "DELETE FROM api_admin.oauth_refresh_tokens WHERE token = %s",
                (old_token,),
            )
    except Exception:
        logger.exception("DB refresh token delete failed")
    return _db_issue_refresh_token(api_key, scope, client_id)


def _db_get_refresh_token(token: str) -> dict[str, Any] | None:
    try:
        with _oauth_db(read_only=True) as cur:
            cur.execute(
                "SELECT token, api_key, client_id, scope "
                "FROM api_admin.oauth_refresh_tokens "
                "WHERE token = %s AND expires_at > now()",
                (token,),
            )
            row = cur.fetchone()
            if row:
                return dict(row)
    except Exception:
        logger.exception("DB refresh token lookup failed")
    return None


def _db_delete_access_token(token: str) -> None:
    try:
        with _oauth_db(read_only=False) as cur:
            cur.execute("DELETE FROM api_admin.oauth_access_tokens WHERE token = %s", (token,))
    except Exception:
        pass


def _db_delete_refresh_token(token: str) -> None:
    try:
        with _oauth_db(read_only=False) as cur:
            cur.execute("DELETE FROM api_admin.oauth_refresh_tokens WHERE token = %s", (token,))
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Auth code helpers (in-memory only — restart-safe to lose, 5-min TTL)
# ---------------------------------------------------------------------------

def _cleanup_auth_codes():
    now = time.time()
    with _lock:
        expired = [k for k, v in _auth_codes.items() if now > v["expires_at"]]
        for k in expired:
            _auth_codes.pop(k, None)


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


def _error_page(title: str, message: str) -> str:
    """Styled error page matching the authorize form design."""
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{title} — FPDS Analytics</title>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
               background: #0f172a; color: #e2e8f0; display: flex; justify-content: center;
               align-items: center; min-height: 100vh; margin: 0; }}
        .card {{ background: #1e293b; border-radius: 12px; padding: 2rem; max-width: 520px; width: 100%; box-shadow: 0 8px 32px rgba(0,0,0,0.3); }}
        h1 {{ color: #f87171; font-size: 1.4rem; margin: 0 0 1rem; }}
        p {{ color: #94a3b8; font-size: 0.9rem; line-height: 1.6; }}
        .help {{ background: #1a2332; border-radius: 8px; padding: 1rem; margin-top: 1.5rem; }}
        .help h2 {{ color: #60a5fa; font-size: 0.85rem; margin: 0 0 0.5rem; }}
        .help ul {{ color: #94a3b8; font-size: 0.82rem; line-height: 1.6; padding-left: 1.2rem; margin: 0; }}
        .footer {{ text-align: center; margin-top: 1.5rem; font-size: 0.75rem; color: #64748b; }}
    </style>
</head>
<body>
    <div class="card">
        <h1>{title}</h1>
        <p>{message}</p>
        <div class="help">
            <h2>What you can do</h2>
            <ul>
                <li>Use Claude Desktop or Claude.ai — add FPDS Analytics as a custom connector and OAuth starts automatically</li>
                <li>Use the REST API directly — <a href="https://analytics-api.kenosaconsulting.com/v1/signup" style="color:#60a5fa">get an API key</a> and pass it as X-Api-Key header</li>
                <li>Connect via MCP — point any MCP client at <code style="color:#cbd5e1">https://analytics-api.kenosaconsulting.com/v1/mcp</code></li>
            </ul>
        </div>
        <div class="footer">Kenosa Consulting · FPDS Analytics</div>
    </div>
</body>
</html>"""


# ---------------------------------------------------------------------------
# Well-known endpoints
# ---------------------------------------------------------------------------

@router.get("/.well-known/oauth-protected-resource")
@router.get("/.well-known/oauth-protected-resource/mcp")
def protected_resource_metadata(request: Request) -> dict[str, Any]:
    """RFC 9728 protected resource metadata.
    Tells MCP clients where to find the authorization server.
    
    Two paths are served:
    - /.well-known/oauth-protected-resource (standard)
    - /.well-known/oauth-protected-resource/mcp (path-suffixed variant per RFC 9728 §3.1)
      Claude tries this first when the MCP URL has a path component (/v1/mcp).
    """
    base = _base_url(request)
    return {
        "resource": f"{base}/v1/mcp",
        "authorization_servers": [base],
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
        parsed = urlparse(uri)
        if parsed.hostname in ("claude.ai", "anthropic.com") and parsed.scheme == "https":
            valid_redirects.append(uri)
        elif parsed.hostname in ("localhost", "127.0.0.1") and parsed.scheme == "http":
            valid_redirects.append(uri)

    _db_register_client(
        client_id, client_secret, body.client_name,
        valid_redirects, body.grant_types,
        body.token_endpoint_auth_method, body.scope,
    )

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
    client = _db_get_client(client_id)
    if not client:
        return HTMLResponse(_error_page("Unknown Client", (
            "This authorization request came from an unrecognized application. "
            "FPDS Analytics uses OAuth 2.0 Dynamic Client Registration — "
            "applications like Claude.ai register automatically when you add "
            "them as a custom connector. If you're testing this URL directly, "
            "the client must first register via the OAuth metadata flow."
        )), status_code=400)

    if redirect_uri not in client["redirect_uris"]:
        return HTMLResponse(_error_page("Invalid Redirect", (
            f"The redirect URI is not registered for client <strong>{client['client_name']}</strong>. "
            "This is a security measure to prevent open redirect attacks. "
            "If you believe this is an error, re-add the connector to trigger re-registration."
        )), status_code=400)

    if response_type != "code":
        return HTMLResponse(_error_page("Unsupported", (
            "Only the 'code' response type (Authorization Code flow with PKCE) "
            "is supported. Your client requested an unsupported response type."
        )), status_code=400)

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
            <a href="https://analytics-api.kenosaconsulting.com/v1/signup" target="_blank">
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
    _cleanup_auth_codes()

    # Validate client
    client = _db_get_client(client_id)
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
    with _lock:
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
    _cleanup_auth_codes()

    # Authenticate client
    client = _db_get_client(client_id)
    if not client:
        return JSONResponse(
            status_code=401,
            content={"error": "invalid_client", "error_description": "Unknown client ID"},
        )

    # Validate client secret (skip for public clients with method "none")
    if client.get("token_endpoint_auth_method") != "none":
        if not hmac.compare_digest(client.get("client_secret", ""), client_secret):
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
    with _lock:
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

        # Consume the code (atomically under lock)
        api_key = entry["api_key"]
        scope = entry["scope"]
        _auth_codes.pop(code, None)

    # Issue tokens
    access_token = _db_issue_access_token(api_key, scope, client_id)
    if not access_token:
        return JSONResponse(
            status_code=500,
            content={"error": "server_error", "error_description": "Failed to issue access token"},
        )
    token_response: dict[str, Any] = {
        "access_token": access_token,
        "token_type": "Bearer",
        "expires_in": _ACCESS_TOKEN_TTL,
        "scope": scope,
    }

    # Issue refresh token if offline_access scope was requested
    if "offline_access" in scope:
        refresh_tok = _db_issue_refresh_token(api_key, scope, client_id)
        if refresh_tok:
            token_response["refresh_token"] = refresh_tok

    return JSONResponse(content=token_response)


def _handle_refresh_token(refresh_token: str, client_id: str, client: dict) -> JSONResponse:
    """Process refresh_token grant."""
    entry = _db_get_refresh_token(refresh_token)
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

    # Rotate: invalidate old refresh token, issue new ones
    api_key = entry["api_key"]
    scope = entry["scope"]

    access_token = _db_issue_access_token(api_key, scope, client_id)
    if not access_token:
        return JSONResponse(
            status_code=500,
            content={"error": "server_error", "error_description": "Failed to issue access token"},
        )
    new_refresh = _db_rotate_refresh_token(refresh_token, api_key, scope, client_id)

    response_content: dict[str, Any] = {
        "access_token": access_token,
        "token_type": "Bearer",
        "expires_in": _ACCESS_TOKEN_TTL,
        "scope": scope,
    }
    if new_refresh:
        response_content["refresh_token"] = new_refresh

    return JSONResponse(content=response_content)


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
    client = _db_get_client(client_id)
    if not client or not hmac.compare_digest(client.get("client_secret", ""), client_secret):
        return JSONResponse(content={"active": False})

    api_key = resolve_access_token(token)
    if not api_key:
        return JSONResponse(content={"active": False})

    return JSONResponse(content={
        "active": True,
        "client_id": client_id,
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
    client = _db_get_client(client_id)
    if not client or not hmac.compare_digest(client.get("client_secret", ""), client_secret):
        return Response(status_code=401)

    _db_delete_access_token(token)
    _db_delete_refresh_token(token)
    return Response(status_code=200)
