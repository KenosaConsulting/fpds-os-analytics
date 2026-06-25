# OpenClaw Integration Guide

This guide helps any team using [OpenClaw](https://openclaw.ai) as their agent
infrastructure layer connect to the FPDS Analytics API and MCP server.

It covers two things:

1. **Configuration** — getting an API key, storing it securely, and wiring the
   MCP server into OpenClaw so your agents can query federal procurement data.
2. **Skills** — pre-built instruction sets for common government contracting
   activities that any OpenClaw session can pick up.

If your team uses a different agent runtime (Claude Desktop, Cursor, VS Code),
the MCP server works there too — see [MCP Clients](#other-mcp-clients) below.

---

## Prerequisites

- An OpenClaw installation (`npm install -g openclaw`)
- A running OpenClaw gateway (`openclaw gateway`)
- Python 3.10+ (for the MCP server)
- This repo cloned locally

---

## 1. Get an API Key

Visit **[kenosaconsulting.com/api](https://kenosaconsulting.com/api)** to request
an API key.

**What the key gets you:**
- Access to 81 analytics datasets (99M+ federal contract actions)
- Higher rate limits and larger response caps
- Access to partner-tier endpoints (exports, bulk queries)
- Use with the MCP server for agent-driven analysis

**Without a key**, the API still works for bounded public queries — but with
lower rate limits and smaller response caps. For production agent workflows,
you'll want a key.

---

## 2. Store the API Key

How you store the key depends on your system and your OpenClaw configuration.
Your OpenClaw agent can help you store it securely — just tell it:

> "Store my FPDS Analytics API key."

OpenClaw supports several credential storage methods natively:

| Method | Best for | Example |
|--------|----------|---------|
| **macOS Keychain** | Mac-based teams | `security add-generic-password -s "fpds-analytics-api" -a "$USER" -w "YOUR_KEY"` |
| **Environment variable** | Linux / containers / CI | `export FPDS_API_KEY="YOUR_KEY"` in `~/.zshrc` or `~/.bashrc` |
| **Secret file** | Shared dev machines | `echo "YOUR_KEY" > ~/.config/fpds-api-key && chmod 600 ~/.config/fpds-api-key` |
| **Vault / cloud secrets** | Enterprise deployments | Depends on your vault — OpenClaw's `SecretRef` supports `env`, `file`, and `exec` providers |

**The key point:** OpenClaw doesn't mandate a specific storage method. Pick the
one that fits your infrastructure and security requirements. Your agent can
detect what's available and use the appropriate method.

The environment variable `FPDS_API_KEY` is the convention the MCP server looks
for. If you store the key in Keychain or a file, make sure it ends up in
`FPDS_API_KEY` when your OpenClaw sessions run.

---

## 3. Install the MCP Server

The FPDS Analytics MCP server is a stdio-based server — it runs as a subprocess
that OpenClaw (or any MCP-compatible client) spawns and communicates with via
JSON-RPC over stdin/stdout.

### From source (this repo)

```bash
git clone https://github.com/KenosaConsulting/fpds-os-analytics.git
cd fpds-os-analytics
pip install -e .
```

### Verify it runs

```bash
export FPDS_API_KEY="your-key-here"
python -m mcp.fpds_mcp_server --help
```

You should see usage information. If you get an import error, make sure you're
in the right virtual environment and installed with `pip install -e .`.

---

## 4. Configure OpenClaw to Use the MCP Server

OpenClaw doesn't have a single "MCP config file" — instead, MCP servers are
registered as tools that your agent can call. The exact configuration depends
on how your OpenClaw deployment is structured. Here are the common patterns:

### Pattern A: Local stdio MCP (simplest)

If your OpenClaw gateway runs on the same machine as the MCP server, add the
MCP server as a local tool in your `openclaw.json`:

```json
{
  "tools": {
    "mcp": {
      "servers": {
        "fpds-analytics": {
          "command": "python",
          "args": ["-m", "mcp.fpds_mcp_server"],
          "cwd": "/path/to/fpds-os-analytics",
          "env": {
            "FPDS_API_KEY": { "env": "FPDS_API_KEY" },
            "FPDS_ANALYTICS_API_BASE_URL": "https://analytics-api.kenosaconsulting.com"
          }
        }
      }
    }
  }
}
```

OpenClaw resolves the `FPDS_API_KEY` environment variable from your shell or
Keychain at runtime. The MCP server starts automatically when your agent first
calls an FPDS tool.

### Pattern B: Custom tool wrapper

Some teams prefer to wrap the MCP server in a custom tool definition. This gives
you more control over which tools are exposed and how they're named:

```json
{
  "tools": {
    "profile": "coding",
    "mcp": {
      "servers": {
        "fpds": {
          "command": "python",
          "args": ["-m", "mcp.fpds_mcp_server"],
          "cwd": "/path/to/fpds-os-analytics",
          "env": {
            "FPDS_API_KEY": { "env": "FPDS_API_KEY" }
          }
        }
      }
    }
  }
}
```

### Pattern C: Remote MCP (future)

A remote HTTP MCP endpoint is on the roadmap (see [issue #4](https://github.com/KenosaConsulting/fpds-os-analytics/issues/4)).
Once deployed, you'll be able to point OpenClaw at a URL instead of running the
server locally. This is useful for teams that don't want to manage Python
dependencies.

---

## 5. Available MCP Tools

Once configured, your OpenClaw agent gains access to these tools:

| Tool | Purpose |
|------|---------|
| `fpds_list_datasets` | Browse the catalog of 81 analytics datasets |
| `fpds_describe_dataset` | Get fields, filters, sorts, and caveats for a dataset |
| `fpds_query_dataset` | Query a dataset with filters and return structured rows |
| `fpds_list_dimensions` | Browse lookup tables (departments, agencies, NAICS, PSC, etc.) |
| `fpds_lookup_dimension` | Look up a specific FPDS code |
| `fpds_resolve` | Resolve a department/agency/office name to its FPDS code |
| `fpds_customer_profile` | Get a full customer profile for a department or agency |
| `fpds_topic_search` | Search datasets by topic keyword |

Your agent can call these tools directly in conversation. For example:

> "Who are the top 10 vendors in Army IT services?"

The agent will call `fpds_resolve` to find the Army's department code, then
`fpds_query_dataset` on the `concentration.vendor_market_leaders` dataset with
the right filters, then explain the results.

---

## 6. Skills

Pre-built skills for common government contracting activities live in the
[`/skills`](../skills) folder. Each skill is a markdown file with instructions
that any OpenClaw session can pick up.

See [`/skills/README.md`](../skills/README.md) for the full catalog.

Current skills:

| Skill | Activity |
|-------|----------|
| [`vendor-market-analysis`](../skills/vendor-market-analysis/SKILL.md) | Analyze vendor market share and competitive landscape for a target agency and NAICS |
| [`recompete-pipeline`](../skills/recompete-pipeline/SKILL.md) | Identify upcoming recompete opportunities and build a recompete watchlist |
| [`contracting-officer-patterns`](../skills/contracting-officer-patterns/SKILL.md) | Analyze contracting office buying patterns and contract officer behavior |
| [`account-plan-builder`](../skills/account-plan-builder/SKILL.md) | Build a structured account plan for a federal customer |
| [`naics-opportunity-scan`](../skills/naics-opportunity-scan/SKILL.md) | Scan a NAICS code across agencies to find growth opportunities |

To use a skill, either:
- Copy the `SKILL.md` file into your OpenClaw workspace's skills directory
- Or point OpenClaw's skill loader at this repo's `/skills` folder

---

## 7. Other MCP Clients

The MCP server works with any MCP-compatible client, not just OpenClaw:

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS):

```json
{
  "mcpServers": {
    "fpds-analytics": {
      "command": "python",
      "args": ["-m", "mcp.fpds_mcp_server"],
      "cwd": "/path/to/fpds-os-analytics",
      "env": {
        "FPDS_API_KEY": "your-key-here",
        "FPDS_ANALYTICS_API_BASE_URL": "https://analytics-api.kenosaconsulting.com"
      }
    }
  }
}
```

### Cursor

Add to `.cursor/mcp.json` in your project:

```json
{
  "mcpServers": {
    "fpds-analytics": {
      "command": "python",
      "args": ["-m", "mcp.fpds_mcp_server"],
      "cwd": "/path/to/fpds-os-analytics",
      "env": {
        "FPDS_API_KEY": "your-key-here"
      }
    }
  }
}
```

### VS Code (Continue.dev or similar)

Follow the MCP server configuration for your specific extension. The server
command is always:

```
python -m mcp.fpds_mcp_server
```

with `FPDS_API_KEY` and `FPDS_ANALYTICS_API_BASE_URL` set in the environment.

---

## 8. Troubleshooting

**MCP server won't start:**
- Verify Python 3.10+ is installed: `python --version`
- Verify the package is installed: `pip show fpds-os-analytics`
- Run the server manually to see errors: `python -m mcp.fpds_mcp_server`
- Check that `FPDS_API_KEY` is set in the environment OpenClaw uses

**Agent can't find FPDS tools:**
- Check that the MCP server is registered in your OpenClaw config
- Restart the gateway after config changes: `openclaw gateway restart`
- Verify the server path: OpenClaw needs to find `mcp.fpds_mcp_server` in its Python path

**API returns 401 or 403:**
- Verify your API key is valid at [kenosaconsulting.com/api](https://kenosaconsulting.com/api)
- Check that the key is being passed correctly (the MCP server sends it as `X-Api-Key` header)
- If using environment variables, make sure they're loaded in the shell that runs OpenClaw

**Queries return empty results:**
- Start with `fpds_list_datasets` to see what's available
- Use `fpds_resolve` to find the correct department/agency/office codes for your query
- Check dataset caveats with `fpds_describe_dataset` — some datasets have date ranges or coverage gaps

---

## Need Help?

- **API key issues:** [kenosaconsulting.com/api](https://kenosaconsulting.com/api)
- **Bug reports:** [GitHub Issues](https://github.com/KenosaConsulting/fpds-os-analytics/issues)
- **OpenClaw docs:** [docs.openclaw.ai](https://docs.openclaw.ai)
- **FPDS Analytics docs:** [docs/](docs/) in this repo

---

*This guide is intentionally broad. Each team's OpenClaw deployment is different —
adjust the configuration to fit your infrastructure. The goal is to get the MCP
server functional so your agents can start querying federal procurement data.
How you use the data after that is up to you.*
