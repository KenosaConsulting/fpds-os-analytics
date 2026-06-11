# FPDS ATOM Harvest

This directory stores the FPDS-021b raw ATOM capture.

- `input/`: copied Step-0 PIID manifest used for the run
- `raw/`: raw page XML responses, grouped one directory per PIID
- `logs/fetch-log.jsonl`: append-only per-PIID fetch outcomes
- `logs/summary.json`: run summary

Step 1 is raw capture only. XML parsing/classification is deferred to FPDS-021i.
