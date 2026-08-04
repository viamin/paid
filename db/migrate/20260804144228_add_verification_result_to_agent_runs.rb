# frozen_string_literal: true

class AddVerificationResultToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :verification_result, :jsonb, default: {}, null: false,
      comment: "Persisted interactive self-verification outcome and related artifacts for verification-enabled agent runs."
  end
end
