# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe ShadowEvaluationExecutionJob do
  let(:project) { create(:project) }
  let(:evaluation) { create(:intent_conformance_shadow_evaluation, project: project) }

  it "does not execute a cancelled evaluation" do
    evaluation.update!(status: "cancelled", labels_frozen_at: Time.current)

    expect(IntentConformance::ShadowEvaluation::ExecuteReviewer).not_to receive(:call)

    described_class.perform_now(project.id, evaluation.id)
  end

  it "runs the shared reviewer service for a queued evaluation" do
    evaluation.update!(status: "queued", labels_frozen_at: Time.current)
    result = instance_double(IntentConformance::ShadowEvaluation::ExecuteReviewer::Result, success?: true)
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call).and_return(result)
    allow(IntentConformance::ShadowEvaluation::CompileReport).to receive(:call)

    described_class.perform_now(project.id, evaluation.id)

    expect(IntentConformance::ShadowEvaluation::ExecuteReviewer).to have_received(:call).with(evaluation: evaluation)
  end

  it "converges an unsuccessful service result to a retryable terminal state" do
    evaluation.update!(status: "queued", labels_frozen_at: Time.current)
    create(:intent_conformance_shadow_evaluation_run, shadow_evaluation: evaluation)
    result = IntentConformance::ShadowEvaluation::ExecuteReviewer::Result.new(
      success: false,
      error: "corpus manifest changed",
      evaluation: nil,
      executed: 0,
      failed: 0
    )
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call).and_return(result)
    allow(IntentConformance::ShadowEvaluation::CompileReport).to receive(:call)

    described_class.perform_now(project.id, evaluation.id)

    expect(evaluation.reload).to have_attributes(status: "partial", last_failure_reason: "corpus manifest changed")
    expect(IntentConformance::ShadowEvaluation::CompileReport).to have_received(:call).with(evaluation: evaluation)
  end
end
