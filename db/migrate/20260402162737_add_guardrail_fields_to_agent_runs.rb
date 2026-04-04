# frozen_string_literal: true

class AddGuardrailFieldsToAgentRuns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :agent_runs, :guardrail_violation_type, :string, limit: 50 unless column_exists?(:agent_runs, :guardrail_violation_type)
    add_column :agent_runs, :guardrail_context, :jsonb unless column_exists?(:agent_runs, :guardrail_context)
    add_column :agent_runs, :paused_at, :datetime unless column_exists?(:agent_runs, :paused_at)

    unless index_exists?(:agent_runs, :guardrail_violation_type, where: "guardrail_violation_type IS NOT NULL")
      add_index :agent_runs,
        :guardrail_violation_type,
        where: "guardrail_violation_type IS NOT NULL",
        algorithm: :concurrently
    end
  end

  def down
    if index_exists?(:agent_runs, :guardrail_violation_type, where: "guardrail_violation_type IS NOT NULL")
      remove_index :agent_runs,
        :guardrail_violation_type,
        where: "guardrail_violation_type IS NOT NULL",
        algorithm: :concurrently
    end

    remove_column :agent_runs, :paused_at, :datetime if column_exists?(:agent_runs, :paused_at)
    remove_column :agent_runs, :guardrail_context, :jsonb if column_exists?(:agent_runs, :guardrail_context)
    remove_column :agent_runs, :guardrail_violation_type, :string if column_exists?(:agent_runs, :guardrail_violation_type)
  end
end
