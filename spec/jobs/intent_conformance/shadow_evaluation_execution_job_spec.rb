# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluationExecutionJob do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:evaluation) { create(:intent_conformance_shadow_evaluation, :frozen, project:, solo_maintainer: owner, created_by: owner) }

  it "marks a cancelled execution without fabricating unevaluated runs" do
    evaluation.update!(status: "queued", cancellation_requested_at: Time.current)

    described_class.perform_now(evaluation.id)

    expect(evaluation.reload).to be_cancelled
    expect(evaluation.runs).to be_empty
  end

  it "compiles an available report after the executor returns" do
    evaluation.update!(status: "queued")
    evaluation.runs.create!(case_id: "A-01", verdict: "within_scope", reviewer_run_id: "r1", reviewer_model: "model",
      prompt_digest: "digest", cost_cents: 12, recorded_at: Time.current)
    result = instance_double(IntentConformance::ShadowEvaluation::ExecuteReviewer::Result, success?: true)
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call).and_return(result)
    allow(IntentConformance::ShadowEvaluation::CompileReport).to receive(:call)

    described_class.perform_now(evaluation.id)

    expect(IntentConformance::ShadowEvaluation::CompileReport).to have_received(:call).with(evaluation: evaluation)
  end
end
