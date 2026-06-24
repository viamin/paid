# frozen_string_literal: true

class AddIssueRunnerRetryCapToProjectsAndIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :max_issue_runner_failures, :integer,
      comment: "Per-project override for the per-issue per-provider retry cap. " \
               "When nil, the account-level agent setting (default 10) applies. " \
               "After a provider fails this many times for a single issue it is " \
               "excluded from scheduling for that issue."
    add_column :issues, :runner_retry_abandoned_at, :datetime,
      comment: "When non-null, the issue was abandoned because every available " \
               "provider reached the per-issue retry cap. Excluded from auto-pick " \
               "until cleared (e.g. by a successful run)."
    add_column :issues, :runner_retry_abandon_reason, :text,
      comment: "Human-readable reason the issue was abandoned due to the retry cap."
  end
end
