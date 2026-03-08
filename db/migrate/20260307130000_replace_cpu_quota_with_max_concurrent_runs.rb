# frozen_string_literal: true

class ReplaceCpuQuotaWithMaxConcurrentRuns < ActiveRecord::Migration[8.1]
  # NO-OP shim migration.
  #
  # This migration originally contained conversion logic from container_cpu_quota
  # to max_concurrent_runs, but it duplicated and conflicted with
  # 20260307010138_replace_container_cpu_quota_with_max_concurrent_runs.
  # It has been converted into a no-op to preserve migration ordering.
  #
  # Migration 20260307010138 serves as the idempotent "repair" migration:
  # it uses column_exists? guards so it converges the schema correctly even
  # on databases that previously ran the old version of this migration.
  def up
    # Intentionally left blank: this migration is a no-op shim.
  end

  def down
    # Intentionally left blank: this migration is reversible as a no-op.
  end
end
