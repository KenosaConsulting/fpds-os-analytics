# FPDS Analytics Skills

Pre-built instruction sets for common government contracting activities.
Each skill is a markdown file that any OpenClaw session (or any MCP-compatible
agent) can pick up to guide a repetitive analytical workflow.

## How to Use

### With OpenClaw

Copy a skill's `SKILL.md` into your workspace's skills directory, or point
OpenClaw's skill loader at this folder. Once loaded, the agent follows the
instructions when the activity is triggered.

### With Claude Desktop / Cursor / VS Code

The skills are plain markdown. Paste the contents of a `SKILL.md` into your
assistant's system prompt or custom instructions, and it will follow the
workflow using the FPDS MCP tools.

### With any LLM

These skills work with any assistant that can call the FPDS Analytics API or
MCP server. The instructions are tool-agnostic — they describe *what* to do,
not *which* tool to call.

## Skill Catalog

| Skill | Activity | Datasets Used |
|-------|----------|---------------|
| [vendor-market-analysis](vendor-market-analysis/SKILL.md) | Analyze vendor market share and competitive landscape | `concentration.vendor_market_leaders`, `concentration.vendor_office_naics_year` |
| [recompete-pipeline](recompete-pipeline/SKILL.md) | Identify upcoming recompete opportunities | `pipeline.recompete_watchlist`, `customer.office_month_naics_fy` |
| [contracting-officer-patterns](contracting-officer-patterns/SKILL.md) | Analyze contracting office buying patterns | `customer.office_month_naics_fy`, `contacts.*` |
| [account-plan-builder](account-plan-builder/SKILL.md) | Build a structured account plan | Multiple — customer intelligence, vendor concentration, recompete pipeline |
| [naics-opportunity-scan](naics-opportunity-scan/SKILL.md) | Scan a NAICS code for growth opportunities | `naics.growth_leaders`, `geography.state_naics_fy`, `concentration.vendor_market_leaders` |

## Activity Taxonomy

The skills are organized around five core govcon activities:

1. **Market Analysis** — Who's winning, who's competing, how concentrated is the market?
2. **Pipeline Intelligence** — What's expiring, what's recompeting, when does the opportunity hit?
3. **Customer Intelligence** — Who's buying, how do they buy, what are their patterns?
4. **Account Planning** — Synthesize everything into an actionable plan for a target customer.
5. **Opportunity Scanning** — Find growth pockets across agencies or geographies.

Each skill can be used standalone or combined. The account-plan-builder skill,
for example, draws on outputs from the other four.

## Contributing

Skills are just markdown files. If you build one that works for your team,
submit a PR. The format is:

```
skills/
  your-skill-name/
    SKILL.md
```

See an existing skill's `SKILL.md` for the format.

## License

Same as the repo — MIT.
