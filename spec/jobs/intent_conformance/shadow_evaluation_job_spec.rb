# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluationJob do
  let(:evaluation) { create(:intent_conformance_shadow_evaluation, :frozen) }

  it "runs the persisted evaluation and attaches an available report" do
    create(:intent_conformance_shadow_evaluation_run, shadow_evaluation: evaluation)
    result = instance_double(IntentConformance::ShadowEvaluation::ExecuteReviewer::Result, success?: true)
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call).and_return(result)
    allow(IntentConformance::ShadowEvaluation::CompileReport).to receive(:call)

    described_class.perform_now(evaluation.project_id, evaluation.id)

    expect(IntentConformance::ShadowEvaluation::ExecuteReviewer).to have_received(:call)
      .with(evaluation: evaluation)
    expect(IntentConformance::ShadowEvaluation::CompileReport).to have_received(:call)
      .with(evaluation: evaluation)
  end

  it "does not spend again when cancellation was requested before the worker starts" do
    evaluation.update!(status: "cancelled", cancel_requested_at: Time.current)

    expect(IntentConformance::ShadowEvaluation::ExecuteReviewer).not_to receive(:call)

    described_class.perform_now(evaluation.project_id, evaluation.id)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-011
  it "retains partial evidence when an interrupted worker is retried" do
    create(:intent_conformance_shadow_evaluation_run, shadow_evaluation: evaluation)
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call).and_raise(Timeout::Error, "provider stalled")

    expect { described_class.perform_now(evaluation.project_id, evaluation.id) }
      .to raise_error(Timeout::Error, "provider stalled")

    expect(evaluation.reload).to be_partial
    expect(evaluation.last_failure_reason).to eq("provider stalled")
  end
end
