# Documentation Audit Report

## DATA_MODEL retirement

`docs/DATA_MODEL.md` is being retired in favor of PostgreSQL schema comments dumped into [`db/schema.rb`](../db/schema.rb).

- `db/schema.rb` is generated from the actual database, so it does not drift.
- Table and column comments added in migrations keep intent next to the schema changes that introduced it.
- `docs/DATA_MODEL.md` had already drifted from the live schema and should no longer be treated as authoritative.
