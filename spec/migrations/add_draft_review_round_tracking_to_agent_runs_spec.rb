# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260404062147_add_draft_review_round_tracking_to_agent_runs")

RSpec.describe AddDraftReviewRoundTrackingToAgentRuns, :aggregate_failures do
  let(:migration) { described_class.new }

  it "is reversible and re-applicable" do
    # Columns exist after migrations have run
    expect(AgentRun.column_names).to include(
      "count_toward_draft_review_round",
      "expected_draft_review_count"
    )

    # Round-trip: down removes, up restores
    migration.down
    AgentRun.reset_column_information
    expect(AgentRun.column_names).not_to include("count_toward_draft_review_round")
    expect(AgentRun.column_names).not_to include("expected_draft_review_count")

    migration.up
    AgentRun.reset_column_information
    expect(AgentRun.column_names).to include(
      "count_toward_draft_review_round",
      "expected_draft_review_count"
    )
  end
end
