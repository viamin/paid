# frozen_string_literal: true

class ReplaceCpuQuotaWithMaxConcurrentRuns < ActiveRecord::Migration[8.1]
  # NO-OP shim migration.
  #
  # The actual conversion from container_cpu_quota to max_concurrent_runs
  # is implemented in 20260307010138_replace_container_cpu_quota_with_max_concurrent_runs.
  # This migration originally duplicated that logic and was irreversible, which
  # made rolling back past this point impossible. It has been converted into a
  # no-op while being kept in place to preserve migration ordering.
  #
  # Running this migration now has no effect on the schema. Rolling it back
  # also has no effect; it simply moves the schema version pointer.
  def up
    # Intentionally left blank: this migration is a no-op shim.
  end

  def down
    # Intentionally left blank: this migration is reversible as a no-op.
  end
end
