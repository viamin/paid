# frozen_string_literal: true

# Routine updates consume the committed schemas. Dumping a long-lived local
# database creates drift that can conflict when the next update restores edits.
# Explicit db:schema:dump and normal migration development keep Rails defaults.
# @spec POSTGRESQL-PERSISTENCE-011
ActiveRecord.dump_schema_after_migration = false if ENV["PAID_SKIP_AUTO_SCHEMA_DUMP"] == "1"
