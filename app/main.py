"""FastAPI app for the public FPDS Analytics API."""

from __future__ import annotations

import os
from uuid import uuid4

from fastapi import FastAPI, Request
from fastapi.exceptions import HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.catalog import load_catalog
from app.errors import APIError
from app.rate_limit import RateLimitMiddleware
from app.routes import catalog, datasets, dimensions, exports, health, keys, mcp, profiles
from app import oauth


def _allowed_origins() -> list[str]:
    if os.environ.get("FPDS_ANALYTICS_ALLOW_ALL_ORIGINS") == "1":
        return ["*"]
    raw = os.environ.get("FPDS_ANALYTICS_ALLOWED_ORIGINS", "")
    return [origin.strip() for origin in raw.split(",") if origin.strip()]


app = FastAPI(
    title="FPDS Analytics API",
    version=load_catalog().version,
    description="Read-only public API over curated FPDS analytics datasets.",
)

app.add_middleware(RateLimitMiddleware)

app.add_middleware(
    CORSMiddleware,
    allow_origins=_allowed_origins(),
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["X-Api-Key", "X-Api-Version", "Content-Type", "Authorization", "Mcp-Session-Id"],
)


@app.exception_handler(APIError)
async def api_error_handler(request: Request, exc: APIError) -> JSONResponse:
    detail = dict(exc.detail)
    detail["request_id"] = request.headers.get("X-Request-Id") or f"req_{uuid4().hex[:24]}"
    return JSONResponse(status_code=exc.status_code, content={"error": detail})


@app.exception_handler(HTTPException)
async def http_error_handler(request: Request, exc: HTTPException) -> JSONResponse:
    request_id = request.headers.get("X-Request-Id") or f"req_{uuid4().hex[:24]}"
    return JSONResponse(
        status_code=exc.status_code,
        content={
            "error": {
                "type": "http_error",
                "code": "http_error",
                "message": str(exc.detail),
                "param": None,
                "request_id": request_id,
            }
        },
    )


app.include_router(health.router)
app.include_router(catalog.router)
app.include_router(datasets.router)
app.include_router(dimensions.router)
app.include_router(profiles.router)
app.include_router(exports.router)
app.include_router(keys.router)
app.include_router(mcp.router)
app.include_router(oauth.router)
