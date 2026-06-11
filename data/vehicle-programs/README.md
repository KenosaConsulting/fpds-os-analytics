# Vehicle Program Curation

These files are the FPDS-021c source of truth for curated vehicle-program matching.

- `programs.csv`: curated vehicle program registry
- `patterns.csv`: ordered PIID `LIKE` patterns with optional `ref_agency_id` constraint
- `top50_program_spotcheck_queue.csv`: current curated-program queue for later public-total spot checks
- `top50_program_seed_piids.csv`: the first 50 PIIDs from the Step-0 all-years top list, kept as raw seeds while later steps build program rollups

Queue notes:

- `top50_program_spotcheck_queue.csv` is generated from the current curated matches over the Step-0 top-2000 PIID manifest, so it only contains programs already named in `programs.csv`.
- The seed-PIID file preserves the raw high-dollar backlog that still needs Tier-2 classification or pseudo-program handling in later steps.

Priority semantics:

- Lower `priority` wins.
- Specific program patterns must rank ahead of broad catchalls like `GS%`.
- Leave PIIDs unmatched when confidence is weak; Step 4/5 will roll unmatched spend into pseudo-programs.
