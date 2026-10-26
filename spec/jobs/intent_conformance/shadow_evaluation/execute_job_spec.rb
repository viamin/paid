# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::ExecuteJob do
  let(:evaluation) { create(:intent_conformance_shadow_evaluation, status: "queued") }

  it "compiles available evidence after the worker executes the reviewer" do
    evaluation.runs.create!(case_id: "A-01", verdict: "within_scope", reviewer_run_id: "r1", reviewer_model: "m",
      prompt_digest: "d", cost_cents: 42, recorded_at: Time.current)
    result = IntentConformance::ShadowEvaluation::ExecuteReviewer::Result.new(
      success: true, error: nil, evaluation: evaluation, executed: 1, failed: 0
    )
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call).and_return(result)
    allow(IntentConformance::ShadowEvaluation::CompileReport).to receive(:call)

    described_class.perform_now(evaluation.id)

    expect(IntentConformance::ShadowEvaluation::ExecuteReviewer).to have_received(:call).with(evaluation: evaluation)
    expect(IntentConformance::ShadowEvaluation::CompileReport).to have_received(:call).with(evaluation: evaluation)
  end

  it "does not execute a cancelled evaluation" do
    evaluation.update!(status: "cancelled")
    expect(IntentConformance::ShadowEvaluation::ExecuteReviewer).not_to receive(:call)

    described_class.perform_now(evaluation.id)
  end
end
