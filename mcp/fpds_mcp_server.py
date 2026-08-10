"""Standalone stdio MCP server for the FPDS Analytics API.

Architecture:
  - FPDSServer: central dispatch class with tool/prompt/resource registry
  - tools/: one module per tool family, each exports TOOLS dict with handlers
  - Prompts and resources are defined inline (extracted to prompts.py/resources.py next)
  - FPDSClient: HTTP client for the Analytics REST API
  - serve() / handle_message() / main(): stdio transport

Tool modules are loaded lazily by tools/__init__.py.collect_all_tools().
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from .tools import ToolDef, collect_all_tools, collect_tool_schemas
from .prompts import get_all_prompts, PROMPT_HANDLERS, _skill_prompt as _prompt_skill_fn
from .tools.resolve import TYPE_TO_DIMENSION

JSON_HEADERS = {"Accept": "application/json"}
DEFAULT_LIMIT = 25


# ── HTTP Client ──────────────────────────────────────────────────────────────


@dataclass
class FPDSClient:
    api_base_url: str
    api_key: str | None = None

    def __post_init__(self) -> None:
        self.api_base_url = self.api_base_url.rstrip("/")

    @property
    def has_api_key(self) -> bool:
        return bool(self.api_key)

    def get(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        query = _clean_params(params or {})
        url = f"{self.api_base_url}{path}"
        if query:
            url = f"{url}?{urlencode(query, doseq=True)}"
        headers = dict(JSON_HEADERS)
        if self.api_key:
            headers["X-API-Key"] = self.api_key
        request = Request(url, headers=headers)
        with urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))


def _clean_params(params: dict[str, Any]) -> dict[str, Any]:
    clean: dict[str, Any] = {}
    for key, value in params.items():
        if value in (None, "", [], {}):
            continue
        if isinstance(value, list):
            clean[key] = ",".join(str(item) for item in value)
        elif isinstance(value, dict):
            for nested_key, nested_value in value.items():
                if nested_value not in (None, ""):
                    clean[nested_key] = nested_value
        else:
            clean[key] = value
    return clean


def _json_text(payload: Any) -> dict[str, Any]:
    return {
        "content": [
            {
                "type": "text",
                "text": json.dumps(payload, indent=2, sort_keys=True),
            }
        ]
    }


def _prompt_arg(name: str, description: str, required: bool = False) -> dict[str, Any]:
    return {"name": name, "description": description, "required": required}


# ── Server ──────────────────────────────────────────────────────────────────


class FPDSServer:
    """MCP server dispatching tool calls to modular handlers.

    Tools are loaded from the tools/ package. Each tool module exports
    a TOOLS dict mapping tool_name → ToolDef(schema, handler, tier).
    """

    def __init__(self, client: FPDSClient, client_type: str = "rest") -> None:
        self.client = client
        self._tools = collect_all_tools(client_type)
        self._tool_schemas = collect_tool_schemas(client_type)
        self._catalog_cache: dict[str, Any] | None = None
        self._resources_cache: dict[str, dict[str, Any]] | None = None
        self._skill_cache: dict[str, str] | None = None
        self._db: Any = None  # injected for DB-backed tools

    def set_db(self, db: Any) -> None:
        self._db = db

    def resolve(self, arguments: dict[str, Any]) -> dict[str, Any]:
        """Public resolve method (test compatibility, delegates to tool handler)."""
        tool_def = self._tools.get("fpds_resolve")
        if tool_def is None:
            raise ValueError("fpds_resolve tool not registered")
        result = tool_def.handler(self, arguments)
        if isinstance(result, dict) and "content" in result:
            return result
        return result

    def catalog(self) -> dict[str, Any]:
        if self._catalog_cache is None:
            self._catalog_cache = self.client.get("/v1/catalog")
        return self._catalog_cache

    # ── Tool dispatch ───────────────────────────────────────────────────

    def tools(self) -> list[dict[str, Any]]:
        return list(self._tool_schemas)

    def call_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        tool_def = self._tools.get(name)
        if tool_def is None:
            raise ValueError(f"Unknown tool: {name}")
        try:
            result = tool_def.handler(self, arguments)
            if isinstance(result, dict) and "content" in result:
                return result
            return _json_text(result)
        except ValueError as exc:
            raise ValueError(str(exc))
        except Exception as exc:
            raise RuntimeError(f"Tool '{name}' failed: {exc}") from exc

    # ── Resources ────────────────────────────────────────────────────────

    def _load_resources(self) -> dict[str, dict[str, Any]]:
        if self._resources_cache is not None:
            return self._resources_cache
        resources: dict[str, dict[str, Any]] = {}
        docs_dir = os.path.join(os.path.dirname(__file__), "..", "docs")
        resource_defs = [
            ("fpds://docs/methodology", "METHODOLOGY.md", "How every number is computed."),
            ("fpds://docs/datasets", "DATASETS.md", "Field-by-field reference."),
            ("fpds://docs/caveats", "CAVEATS.md", "Data limitations and caveats."),
            ("fpds://docs/ai-assistant-guide", "AI_ASSISTANT_GUIDE.md", "AI assistant usage guide."),
        ]
        for uri, filename, description in resource_defs:
            filepath = os.path.join(docs_dir, filename)
            try:
                with open(filepath) as f:
                    content = f.read()
            except FileNotFoundError:
                content = f"Resource not found: {filename}"
            resources[uri] = {
                "uri": uri, "name": uri.rsplit("/", 1)[-1],
                "description": description, "mimeType": "text/markdown", "text": content,
            }
        try:
            from app.notices import GLOBAL_DATA_NOTICES, AGENCY_CODE_NOTICES, GEOGRAPHY_NOTICES
            notices_text = "# Critical Data Notices\n\n"
            for n in GLOBAL_DATA_NOTICES:
                notices_text += f"- {n}\n"
            for n in AGENCY_CODE_NOTICES:
                notices_text += f"- {n}\n"
            for n in GEOGRAPHY_NOTICES:
                notices_text += f"- {n}\n"
            resources["fpds://docs/notices"] = {
                "uri": "fpds://docs/notices", "name": "notices",
                "description": "Critical interpretation caveats.",
                "mimeType": "text/markdown", "text": notices_text,
            }
        except ImportError:
            pass
        try:
            cat = self.catalog()
            resources["fpds://catalog/datasets"] = {
                "uri": "fpds://catalog/datasets", "name": "datasets",
                "description": "Complete machine-readable catalog.",
                "mimeType": "application/json", "text": json.dumps(cat, indent=2),
            }
            dims = self.client.get("/v1/dimensions")
            resources["fpds://catalog/dimensions"] = {
                "uri": "fpds://catalog/dimensions", "name": "dimensions",
                "description": "Complete list of 17 code-lookup dimensions.",
                "mimeType": "application/json", "text": json.dumps(dims, indent=2),
            }
        except Exception:
            pass
        self._resources_cache = resources
        return resources

    def resources(self) -> list[dict[str, Any]]:
        res = self._load_resources()
        return [
            {"uri": r["uri"], "name": r["name"], "description": r["description"],
             "mimeType": r.get("mimeType")}
            for r in res.values()
        ]

    def read_resource(self, uri: str) -> dict[str, Any]:
        res = self._load_resources()
        if uri not in res:
            raise ValueError(f"Resource not found: {uri}")
        r = res[uri]
        return {"contents": [{
            "uri": r["uri"], "mimeType": r.get("mimeType", "text/markdown"),
            "text": r["text"],
        }]}

    # ── Skills / Prompt definitions ─────────────────────────────────────

    def _load_skills(self) -> dict[str, str]:
        if self._skill_cache is not None:
            return self._skill_cache
        skills_dir = os.path.join(os.path.dirname(__file__), "..", "skills")
        skill_names = [
            "vendor-market-analysis", "recompete-pipeline",
            "contracting-officer-patterns", "account-plan-builder",
            "naics-opportunity-scan", "cross-agency-opportunity-radar",
            "teaming-partner-finder", "vehicle-strategy-advisor",
        ]
        cache: dict[str, str] = {}
        for name in skill_names:
            filepath = os.path.join(skills_dir, name, "SKILL.md")
            try:
                with open(filepath) as f:
                    cache[name] = f.read()
            except FileNotFoundError:
                cache[name] = f"# {name}\n\nSkill file not found."
        self._skill_cache = cache
        return cache

    def prompts(self) -> list[dict[str, Any]]:
        return get_all_prompts()

    def get_prompt(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        handler = PROMPT_HANDLERS.get(name)
        if not handler:
            raise ValueError(f"Unknown prompt: {name}")
        if isinstance(handler, str):
            messages = _prompt_skill_fn(self, name, handler, arguments)
        else:
            messages = handler(arguments)
        return {
            "description": messages[0]["content"]["text"].split("\n")[0] if messages else "",
            "messages": messages,
        }


# ── JSON-RPC message handling ───────────────────────────────────────────────


def handle_message(server: FPDSServer, message: dict[str, Any]) -> dict[str, Any] | None:
    method = message.get("method")
    msg_id = message.get("id")
    params = message.get("params") or {}
    try:
        if method == "initialize":
            return {
                "jsonrpc": "2.0", "id": msg_id,
                "result": {
                    "protocolVersion": params.get("protocolVersion", "2025-03-26"),
                    "serverInfo": {"name": "fpds-os-analytics", "version": "0.2.0"},
                    "capabilities": {"tools": {}, "prompts": {}, "resources": {}},
                },
            }
        if method == "notifications/initialized":
            return None
        if method == "ping":
            return {"jsonrpc": "2.0", "id": msg_id, "result": {}}
        if method == "tools/list":
            return {"jsonrpc": "2.0", "id": msg_id, "result": {"tools": server.tools()}}
        if method == "tools/call":
            return {
                "jsonrpc": "2.0", "id": msg_id,
                "result": server.call_tool(params["name"], params.get("arguments") or {}),
            }
        if method == "prompts/list":
            return {"jsonrpc": "2.0", "id": msg_id, "result": {"prompts": server.prompts()}}
        if method == "prompts/get":
            return {
                "jsonrpc": "2.0", "id": msg_id,
                "result": server.get_prompt(params["name"], params.get("arguments") or {}),
            }
        if method == "resources/list":
            return {"jsonrpc": "2.0", "id": msg_id, "result": {"resources": server.resources()}}
        if method == "resources/read":
            return {"jsonrpc": "2.0", "id": msg_id, "result": server.read_resource(params["uri"])}
        return {
            "jsonrpc": "2.0", "id": msg_id,
            "error": {"code": -32601, "message": f"Method not found: {method}"},
        }
    except KeyError as exc:
        return {
            "jsonrpc": "2.0", "id": msg_id,
            "error": {"code": -32602, "message": f"Invalid params: missing {exc}"},
        }
    except ValueError as exc:
        return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32602, "message": str(exc)}}
    except Exception as exc:
        return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32603, "message": str(exc)}}


# ── Stdio transport ─────────────────────────────────────────────────────────


def serve(server: FPDSServer) -> None:
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            sys.stdout.write(json.dumps(
                {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}},
                separators=(",", ":"),
            ) + "\n")
            sys.stdout.flush()
            continue
        response = handle_message(server, message)
        if response is not None:
            sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
            sys.stdout.flush()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the FPDS Analytics MCP stdio server.")
    parser.add_argument("--api-base-url", default=os.environ.get("FPDS_API_BASE_URL"))
    parser.add_argument("--api-key", default=os.environ.get("FPDS_API_KEY"))
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    if not args.api_base_url:
        sys.stderr.write("Set --api-base-url or FPDS_API_BASE_URL.\n")
        return 2
    serve(FPDSServer(FPDSClient(args.api_base_url, api_key=args.api_key)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
