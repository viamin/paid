# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::ExecuteJob do
  let(:evaluation) { create(:intent_conformance_shadow_evaluation, status: "queued") }

  it "executes only queued work and compiles its available report" do
    result = instance_double(IntentConformance::ShadowEvaluation::ExecuteReviewer::Result, success?: true)
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call).and_return(result)
    allow(IntentConformance::ShadowEvaluation::CompileReport).to receive(:call)

    described_class.perform_now(evaluation.id)

    expect(evaluation.reload).to be_running
    expect(IntentConformance::ShadowEvaluation::ExecuteReviewer).to have_received(:call).with(evaluation: evaluation)
    expect(IntentConformance::ShadowEvaluation::CompileReport).to have_received(:call).with(evaluation: evaluation)
  end

  it "settles an interrupted running evaluation as partial before resuming it" do
    evaluation.update!(status: "running")
    result = instance_double(IntentConformance::ShadowEvaluation::ExecuteReviewer::Result, success?: true)
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call).and_return(result)
    allow(IntentConformance::ShadowEvaluation::CompileReport).to receive(:call)

    described_class.perform_now(evaluation.id)

    expect(evaluation.reload.last_failure_reason).to include("interrupted")
    expect(IntentConformance::ShadowEvaluation::ExecuteReviewer).to have_received(:call)
  end

  it "does not invoke the reviewer after cancellation" do
    evaluation.update!(cancel_requested_at: Time.current, status: "cancelled")

    expect(IntentConformance::ShadowEvaluation::ExecuteReviewer).not_to receive(:call)

    described_class.perform_now(evaluation.id)
  end
end
