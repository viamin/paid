# frozen_string_literal: true

class AddReviewExecutionDiagnosticsToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :review_execution_diagnostics, :jsonb, default: {}, null: false,
      comment: "Sanitized review execution receipt: selected route, terminal agent result, publication attempt and proxy/upstream outcome. Retained after cleanup to diagnose missing review publication (#5396)."
  end
end
