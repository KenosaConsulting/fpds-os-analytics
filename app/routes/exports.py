"""Export placeholder routes."""

from __future__ import annotations

from fastapi import APIRouter, Depends

from app.auth import require_api_key
from app.errors import APIError


router = APIRouter(prefix="/v1")


@router.post("/exports")
def create_export(_api_key_id: str = Depends(require_api_key)) -> dict[str, object]:
    raise APIError(501, "export_not_implemented", "Exports are reserved for phase 2.", error_type="not_implemented")


@router.get("/exports/{export_id}")
def get_export(export_id: str, _api_key_id: str = Depends(require_api_key)) -> dict[str, object]:
    raise APIError(501, "export_not_implemented", f"Export '{export_id}' is not available.", error_type="not_implemented")
