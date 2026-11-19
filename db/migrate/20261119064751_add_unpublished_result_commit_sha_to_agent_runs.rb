# frozen_string_literal: true

class AddUnpublishedResultCommitShaToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :unpublished_result_commit_sha, :string, limit: 40,
      comment: "Local commit retained when publication is rejected; distinct from the last successfully published result_commit_sha."
  end
end
