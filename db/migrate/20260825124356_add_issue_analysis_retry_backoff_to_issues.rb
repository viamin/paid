# frozen_string_literal: true

class AddIssueAnalysisRetryBackoffToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :issue_analysis_next_attempt_at, :datetime,
      comment: "When automatic analyze_issue retries become eligible again after provider exhaustion."
    add_column :issues, :issue_analysis_backoff_set_at, :datetime,
      comment: "When the current automatic analyze_issue provider-exhaustion backoff window was recorded."
  end
end
