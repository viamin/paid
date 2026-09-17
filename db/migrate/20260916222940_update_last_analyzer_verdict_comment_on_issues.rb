# frozen_string_literal: true

# Tightens the column comments on `last_analyzer_sufficient_context` and
# `last_analyzed_at` to reflect that the flag is now written by both
# `analyze_issue` and `enhance_issue` (#3851), while the timestamp still dates
# only the `analyze_issue` verdict. The widening of writers turns the flag into
# a durable, GitHub-independent "last readiness verdict" signal that drives
# completed-issue auto-pick recovery, on top of the analyzer cycle-state role it
# already played.
class UpdateLastAnalyzerVerdictCommentOnIssues < ActiveRecord::Migration[8.1]
  def up
    change_column_comment :issues, :last_analyzer_sufficient_context,
      "Most recent analyze_issue/enhance_issue readiness verdict — whether the issue had enough context to start a create_pr run. Drives the analyzer's cycle-state prompt and completed-issue auto-pick recovery (#3851)."
    change_column_comment :issues, :last_analyzed_at,
      "Timestamp of the most recent analyze_issue verdict. Distinct from issue_analysis_next_attempt_at (which gates automatic retries) so the inbox can surface recency. NOTE: not updated by enhance_issue, so it can be older than last_analyzer_sufficient_context when a later enhance_issue run rewrites the flag."
  end

  def down
    change_column_comment :issues, :last_analyzer_sufficient_context,
      "Most recent analyze_issue verdict — whether the issue had enough context to start a create_pr run. Drives the analyzer's cycle-state prompt so a re-evaluation can be a delta against the prior verdict rather than a repeat of the baseline."
    change_column_comment :issues, :last_analyzed_at,
      "Timestamp of the most recent analyze_issue verdict. Distinct from issue_analysis_next_attempt_at (which gates automatic retries) so the inbox can surface recency."
  end
end
