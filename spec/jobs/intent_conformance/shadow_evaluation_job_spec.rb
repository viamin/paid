# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluationJob do
  let(:evaluation) { create(:intent_conformance_shadow_evaluation, status: "queued") }

  it "compiles available evidence after execution" do
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call)
    allow(IntentConformance::ShadowEvaluation::CompileReport).to receive(:call)

    described_class.perform_now(evaluation.id)

    expect(IntentConformance::ShadowEvaluation::ExecuteReviewer).to have_received(:call).with(evaluation:)
    expect(IntentConformance::ShadowEvaluation::CompileReport).to have_received(:call).with(evaluation:)
  end

  it "leaves a cancelled queued operation terminal" do
    evaluation.update!(execution_cancelled_at: Time.current, status: "cancelled")
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call)

    described_class.perform_now(evaluation.id)

    expect(IntentConformance::ShadowEvaluation::ExecuteReviewer).not_to have_received(:call)
    expect(evaluation.reload).to be_cancelled
  end
end
