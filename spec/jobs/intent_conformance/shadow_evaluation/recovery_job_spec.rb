# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::RecoveryJob do
  it "requeues a worker whose heartbeat expired without deleting case evidence" do
    evaluation = create(:intent_conformance_shadow_evaluation, status: "running", execution_heartbeat_at: 36.minutes.ago)
    evaluation.runs.create!(case_id: "A-01", verdict: "within_scope", reviewer_run_id: "r1", reviewer_model: "m",
      prompt_digest: "d", cost_cents: 42, recorded_at: Time.current)

    expect { described_class.perform_now }
      .to have_enqueued_job(IntentConformance::ShadowEvaluation::ExecuteJob).with(evaluation.id)

    expect(evaluation.reload).to be_queued
    expect(evaluation.runs.find_by(case_id: "A-01")).to have_attributes(verdict: "within_scope", cost_cents: 42)
  end
end
