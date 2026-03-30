# frozen_string_literal: true

class AddDiagnosisFieldsToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :diagnosis_status, :string, limit: 50
    add_column :agent_runs, :diagnosis_issue_url, :string, limit: 500
  end
end
