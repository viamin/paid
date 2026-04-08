# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260404062147_add_draft_review_round_tracking_to_agent_runs")

RSpec.describe AddDraftReviewRoundTrackingToAgentRuns, :aggregate_failures do
  let(:migration) { described_class.new }

  it "adds the tracking columns" do
    # Intentionally no backfill: legacy in-flight runs were already counted
    # at trigger time by the unpatched RecordDraftReviewActivity call.
    # Backfilling would double-count. See migration comment for details.
    expect(AgentRun.column_names).to include(
      "count_toward_draft_review_round",
      "expected_draft_review_count"
    )
  end
end
