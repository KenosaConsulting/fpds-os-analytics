# OpenClaw Integration Guide

This guide helps any team using [OpenClaw](https://openclaw.ai) as their agent
infrastructure layer connect to the FPDS Analytics API and MCP server.

It covers two things:

1. **Configuration** — getting an API key, storing it securely, and wiring the
   MCP server into OpenClaw so your agents can query federal procurement data.
2. **Skills** — pre-built instruction sets for common government contracting
   activities that any OpenClaw session can pick up.

If your team uses a different agent runtime (Claude Desktop, Cursor, VS Code),
the MCP server works there too — see [Other MCP Clients](#other-mcp-clients) below.

---

## Prerequisites

- An OpenClaw installation (`npm install -g openclaw`)
- A running OpenClaw gateway (`openclaw gateway`)
- Python 3.10+ (for the stdio MCP server — not needed for the remote endpoint)

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
| **Environment variable** | Linux / containers / CI | `export FPDS_API_KEY="***"` in `~/.zshrc` or `~/.bashrc` |
| **Secret file** | Shared dev machines | `echo "YOUR_KEY" > ~/.config/fpds-api-key && chmod 600 ~/.config/fpds-api-key` |
| **Vault / cloud secrets** | Enterprise deployments | Depends on your vault — OpenClaw's `SecretRef` supports `env`, `file`, and `exec` providers |

**The key point:** OpenClaw doesn't mandate a specific storage method. Pick the
one that fits your infrastructure and security requirements. Your agent can
detect what's available and use the appropriate method.

The environment variable `FPDS_API_KEY` is the convention the MCP server looks
for. If you store the key in Keychain or a file, make sure it ends up in
`FPDS_API_KEY` when your OpenClaw sessions run.

---

## 3. Connect to the MCP Server

There are two ways to connect your agent to the FPDS Analytics MCP server.

### Option A: Remote MCP Endpoint (simplest — no local install)

The MCP server is hosted at `https://analytics-api.kenosaconsulting.com/v1/mcp`.
Point your agent at the URL — no Python, no local process, no repo clone.

**OpenClaw configuration:**

```json
{
  "tools": {
    "mcp": {
      "servers": {
        "fpds-analytics": {
          "url": "https://analytics-api.kenosaconsulting.com/v1/mcp",
          "transport": "streamable-http",
          "headers": {
            "X-Api-Key": { "env": "FPDS_API_KEY" }
          }
        }
      }
    }
  }
}
```

That's it. OpenClaw connects to the remote MCP server on first tool call.

**For teams without an API key yet:** Remove the `headers` block — the server
works without a key for bounded public queries (lower rate limits).

### Option B: Local stdio MCP server (pip install)

For teams that want the MCP server running locally (lower latency, no network
dependency, works behind firewalls):

```bash
pip install fpds-os-analytics-mcp
```

Then configure OpenClaw to spawn it as a subprocess:

```json
{
  "tools": {
    "mcp": {
      "servers": {
        "fpds-analytics": {
          "command": "fpds-mcp",
          "env": {
            "FPDS_API_KEY": { "env": "FPDS_API_KEY" },
            "FPDS_API_BASE_URL": "https://analytics-api.kenosaconsulting.com"
          }
        }
      }
    }
  }
}
```

The `fpds-mcp` command is installed by the pip package. OpenClaw starts it
automatically when your agent first calls an FPDS tool.

### Which option should I use?

| | Remote (Option A) | Local (Option B) |
|---|---|---|
| **Setup time** | 1 minute | 5 minutes |
| **Dependencies** | None | Python 3.10+ |
| **Network** | Requires internet | Works offline (after install) |
| **Latency** | +50-100ms per call | Local IPC |
| **Firewall** | Needs outbound HTTPS | No inbound/outbound needed |
| **Updates** | Automatic | `pip install --upgrade` |

**Recommendation:** Start with Option A (remote). Switch to Option B if you
need lower latency, offline access, or have firewall constraints.

---

## 4. Available MCP Tools

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

## 5. Skills

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

## 6. Other MCP Clients

The MCP server works with any MCP-compatible client, not just OpenClaw.

### Claude Desktop

**Remote endpoint (recommended):**

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "fpds-analytics": {
      "url": "https://analytics-api.kenosaconsulting.com/v1/mcp",
      "transport": "streamable-http",
      "headers": {
        "X-Api-Key": "your-key-here"
      }
    }
  }
}
```

**Alternative: mcp-remote bridge** (if your Claude Desktop build doesn't support native streamable-http):

```json
{
  "mcpServers": {
    "fpds-analytics": {
      "command": "npx",
      "args": ["mcp-remote", "https://analytics-api.kenosaconsulting.com/v1/mcp"]
    }
  }
}
```

**Local stdio:**

```json
{
  "mcpServers": {
    "fpds-analytics": {
      "command": "fpds-mcp",
      "env": {
        "FPDS_API_KEY": "your-key-here",
        "FPDS_API_BASE_URL": "https://analytics-api.kenosaconsulting.com"
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
      "url": "https://analytics-api.kenosaconsulting.com/v1/mcp",
      "transport": "streamable-http",
      "headers": {
        "X-Api-Key": "your-key-here"
      }
    }
  }
}
```

### VS Code (Continue.dev or similar)

Follow the MCP server configuration for your specific extension. For the local
stdio server, the command is always:

```
fpds-mcp
```

with `FPDS_API_KEY` and `FPDS_API_BASE_URL` set in the environment. For the
remote endpoint, use the URL `https://analytics-api.kenosaconsulting.com/v1/mcp`.

---

## 7. Testing Your Connection

### Test the remote endpoint

```bash
# Check server info
curl -s https://analytics-api.kenosaconsulting.com/v1/mcp | jq .

# List available tools (JSON-RPC)
curl -s -X POST https://analytics-api.kenosaconsulting.com/v1/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq '.result.tools[].name'

# Query a dataset
curl -s -X POST https://analytics-api.kenosaconsulting.com/v1/mcp \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: your-key-here" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fpds_resolve","arguments":{"query":"Army"}}}' | jq .
```

### Test the local stdio server

```bash
# Verify the command is installed
fpds-mcp --help

# Send a test message (tools/list)
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | FPDS_API_BASE_URL=https://analytics-api.kenosaconsulting.com fpds-mcp
```

---

## 8. Troubleshooting

**Remote MCP returns 401 or 403:**
- Verify your API key is valid at [kenosaconsulting.com/api](https://kenosaconsulting.com/api)
- Check that the key is being passed as `X-Api-Key` header
- The server works without a key for bounded queries — if you're getting 401, you're hitting a key-required endpoint

**Local MCP server won't start:**
- Verify Python 3.10+ is installed: `python --version`
- Verify the package is installed: `pip show fpds-os-analytics-mcp`
- Run the server manually to see errors: `fpds-mcp --api-base-url https://analytics-api.kenosaconsulting.com`
- Check that `FPDS_API_KEY` is set in the environment OpenClaw uses

**Agent can't find FPDS tools:**
- For remote: check the URL in your OpenClaw config, verify the endpoint is reachable with curl
- For local: check that `fpds-mcp` is on the PATH OpenClaw uses
- Restart the gateway after config changes: `openclaw gateway restart`

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
