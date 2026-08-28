# frozen_string_literal: true

# @spec EXEC-USAGE-001
class CreateExecutionUsage < ActiveRecord::Migration[8.1]
  TERMINATION_REASONS = %w[completed cancelled timed_out failed evicted].freeze

  def up
    return if table_exists?(:execution_usages)

    create_table :execution_usages, comment: "Per-run infrastructure usage summary used to estimate cloud-provider cost separately from LLM token cost." do |t|
      t.references :agent_run, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.string :runner_backend, limit: 64, null: false, comment: "Execution runner/backend key used for per-host rate resolution (e.g. local, fly_machine)."
      t.string :provider_resource_id, limit: 255, comment: "Cloud-provider resource identifier for cost reconciliation (Fly Machine ID, Cloud Run execution ID, etc.)."
      t.datetime :provisioned_at, null: false, comment: "When the run's cloud resource was first provisioned."
      t.datetime :execution_started_at, comment: "When the agent began executing inside the resource (often equal to or shortly after provisioned_at)."
      t.datetime :completed_at, comment: "When the agent finished executing."
      t.datetime :terminated_at, null: false, comment: "When the cloud resource was torn down; provider-billed runtime ends here."
      t.integer :billed_duration_seconds, null: false, default: 0, comment: "Cloud-billed lifetime of the resource in seconds (terminated_at - provisioned_at)."
      t.decimal :requested_cpu_cores, precision: 6, scale: 3, comment: "CPU cores requested from the cloud provider at admission."
      t.integer :requested_memory_mib, comment: "Memory requested from the cloud provider at admission, in MiB."
      t.integer :requested_disk_gb, comment: "Disk requested from the cloud provider at admission, in GiB."
      t.string :termination_reason, limit: 20, null: false, comment: "Reason the cloud resource terminated: completed, cancelled, timed_out, failed, evicted."
      t.integer :infra_cost_cents, null: false, default: 0, comment: "Estimated (today) or provider-reported (later) infrastructure cost for this run."
      t.integer :rate_cents_per_hour, null: false, default: 0, comment: "Snapshotted rate used for the estimate so later env changes do not re-price this row."

      t.timestamps null: false
    end

    add_index :execution_usages, :agent_run_id, unique: true, name: "index_execution_usages_on_agent_run_id_unique"
    add_index :execution_usages, :runner_backend, name: "index_execution_usages_on_runner_backend"
    add_index :execution_usages, :terminated_at, name: "index_execution_usages_on_terminated_at"

    add_check_constraint :execution_usages,
      "billed_duration_seconds >= 0",
      name: "chk_execution_usages_billed_duration_nonneg"
    add_check_constraint :execution_usages,
      "infra_cost_cents >= 0",
      name: "chk_execution_usages_infra_cost_nonneg"
    add_check_constraint :execution_usages,
      "rate_cents_per_hour >= 0",
      name: "chk_execution_usages_rate_nonneg"
    add_check_constraint :execution_usages,
      "termination_reason IN (#{TERMINATION_REASONS.map { |r| "'#{r}'" }.join(', ')})",
      name: "chk_execution_usages_termination_reason_valid"
    add_check_constraint :execution_usages,
      "(completed_at IS NULL OR completed_at >= provisioned_at) AND terminated_at >= provisioned_at",
      name: "chk_execution_usages_timestamps_ordered"
  end

  def down
    drop_table :execution_usages if table_exists?(:execution_usages)
  end
end
