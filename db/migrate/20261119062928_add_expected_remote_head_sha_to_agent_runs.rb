# frozen_string_literal: true

class AddExpectedRemoteHeadShaToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :expected_remote_head_sha, :string, limit: 40,
      comment: "Immutable PR branch tip captured at checkout admission; the --force-with-lease baseline a publish is entitled to overwrite until superseded by this run's own verified result_commit_sha."
  end
end
