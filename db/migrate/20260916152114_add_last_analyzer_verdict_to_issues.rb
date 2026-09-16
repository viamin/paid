# frozen_string_literal: true

# Persists the most recent `analyze_issue` verdict on the issue so operators can
# see why a lane stalled and so a later analyzer cycle can consume the prior
# reasoning as cycle state (#3842). Without this the verdict lives only in the
# run's stdout log and the analyzer cannot see what it decided last time.
class AddLastAnalyzerVerdictToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :last_analyzer_sufficient_context, :boolean,
      if_not_exists: true,
      comment: "Most recent analyze_issue verdict — whether the issue had enough context to start a create_pr run. Drives the analyzer's cycle-state prompt so a re-evaluation can be a delta against the prior verdict rather than a repeat of the baseline."
    add_column :issues, :last_analyzer_reasoning, :text,
      if_not_exists: true,
      comment: "Reasoning accompanying last_analyzer_sufficient_context, surfaced in the operator inbox so a lane stuck in manual_review can be diagnosed without re-reading the analyzer run's stdout."
    add_column :issues, :last_analyzer_missing_context_areas, :jsonb,
      if_not_exists: true,
      default: [],
      null: false,
      comment: "Missing-context areas the prior analyzer flagged. Threaded into the next analyzer prompt as cycle state so the next verdict is a delta against the previous one."
    add_column :issues, :last_analyzed_at, :datetime,
      if_not_exists: true,
      comment: "Timestamp of the most recent analyze_issue verdict. Distinct from issue_analysis_next_attempt_at (which gates automatic retries) so the inbox can surface recency."
  end
end
