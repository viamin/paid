# frozen_string_literal: true

class AddGuardrailFieldsToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :guardrail_violation_type, :string, limit: 50
    add_column :agent_runs, :guardrail_context, :jsonb
    add_column :agent_runs, :paused_at, :datetime

    add_index :agent_runs, :guardrail_violation_type, where: "guardrail_violation_type IS NOT NULL"
  end
end
