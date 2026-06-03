# LLM Integration Plan

This API is intentionally shaped for LLM tool use: fixed datasets, allowed filters, allowed sorts, bounded limits, and no arbitrary SQL.

For non-technical users, the first integration is not a plugin. It is a clear URL and instruction block:

```text
https://analytics-api.kenosaconsulting.com/v1/ai-assistant-guide
```

Users should be able to paste the hosted URL into ChatGPT, Claude, Gemini, or a similar assistant and ask it to follow the guide. Placeholder domains will not work and will cause assistants to route around the product.

The core idea is simple:

```text
User question
  -> LLM chooses a safe API function
  -> API returns structured FPDS analytics rows
  -> LLM explains what the data means for customer targeting
```

## Recommended Tool Surface

Expose only these functions to LLM clients:

| Tool | API endpoint | Purpose |
|---|---|---|
| `read_ai_assistant_guide` | `GET /v1/ai-assistant-guide` | Understand how to use the API safely for customer targeting analysis |
| `list_datasets` | `GET /v1/catalog` | Discover available analytics packages |
| `describe_dataset` | `GET /v1/datasets/{dataset_id}` | Understand fields, filters, caveats, and sort options |
| `query_dataset` | `GET /v1/datasets/{dataset_id}/rows` | Return bounded analytics rows |
| `list_dimensions` | `GET /v1/dimensions` | Discover lookup tables |
| `lookup_dimension` | `GET /v1/dimensions/{dimension_id}` | Explain FPDS codes |

Do not expose:

- Arbitrary SQL.
- Raw database tables.
- Bulk exports without quota controls.
- Admin endpoints.
- Internal service logs.

## ChatGPT Action

Fastest path: host the API, then create a Custom GPT Action using `openapi.yaml`.

Recommended setup:

- Action schema: import `openapi.yaml`.
- Authentication: API key.
- Header name: `X-Api-Key`.
- GPT instructions: tell the model to call `list_datasets` first unless it already knows the right dataset.
- Response behavior: summarize the returned data, cite dataset caveats, and avoid overclaiming causality.

Suggested Custom GPT instruction:

```text
You help analysts and government contractors understand federal procurement markets using the FPDS Analytics API.

When a user asks about customer targeting, market openness, incumbent strength, buying style, industry demand, or geography:
1. Choose the most relevant dataset.
2. If uncertain, call list_datasets or describe_dataset first.
3. Query only the fields and filters needed to answer the question.
4. Explain the result in plain English.
5. Include caveats from the API response.
6. Do not invent data that was not returned by the API.
```

## Claude Connector / MCP

Best path for Claude: build a remote MCP server that wraps the same safe API functions.

MCP tools should be thin wrappers:

- `fpds_list_datasets`
- `fpds_describe_dataset`
- `fpds_query_dataset`
- `fpds_list_dimensions`
- `fpds_lookup_dimension`

MCP server rules:

- Require an API key or OAuth before calling data endpoints.
- Enforce the same dataset IDs, filters, sorts, and limits as the API.
- Return structured JSON, not prose.
- Let Claude write the analysis from the data.

## Gemini Function Calling

Best path for Gemini: provide function declarations that call the hosted API from the user's application or agent runtime.

Start with one function:

```json
{
  "name": "query_dataset",
  "description": "Query a bounded FPDS analytics dataset to answer federal procurement market questions.",
  "parameters": {
    "type": "object",
    "properties": {
      "dataset_id": {
        "type": "string",
        "description": "Dataset ID from the FPDS Analytics API catalog."
      },
      "filters": {
        "type": "object",
        "description": "Allowed filters for the selected dataset."
      },
      "fields": {
        "type": "array",
        "items": {"type": "string"},
        "description": "Optional list of fields to return."
      },
      "sort": {
        "type": "string",
        "description": "Optional sort field. Prefix with '-' for descending."
      },
      "limit": {
        "type": "integer",
        "description": "Maximum number of rows to return."
      }
    },
    "required": ["dataset_id"]
  }
}
```

## First Integration To Ship

Ship in this order:

1. Hosted API with API-key auth and rate limits.
2. Public AI assistant guide at `/v1/ai-assistant-guide` and a website page that points users to it.
3. ChatGPT Action using `openapi.yaml`.
4. Remote MCP server wrapping the safe functions.
5. Gemini function declaration examples.
6. A short analyst demo: "Find agencies where NAICS 54 is growing but competition is weak."

## Why This Works

The LLM does not need database access. It only needs a safe tool that returns the right analytics package.

That means the public product can support natural-language analysis while preserving the same security boundary as the REST API:

```text
LLM client
  -> REST Action / MCP tool / function call
  -> FPDS Analytics API
  -> analytics_api facade schema
  -> curated report views
```
