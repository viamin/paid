# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260404062147_add_draft_review_round_tracking_to_agent_runs")

RSpec.describe AddDraftReviewRoundTrackingToAgentRuns, :aggregate_failures do
  let(:migration) { described_class.new }

  it "adds tracking columns without backfilling legacy runs" do
    # Legacy in-flight runs were already counted at trigger time by the
    # unpatched RecordDraftReviewActivity call. Backfilling would double-count.
    expect(migration).not_to respond_to(:backfill_legacy_draft_followup_runs!)
  end
end
