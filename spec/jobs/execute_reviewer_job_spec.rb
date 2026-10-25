# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe ExecuteReviewerJob do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, :frozen, project:, solo_maintainer: owner, created_by: owner)
  end

  it "claims queued work and delegates reviewer execution outside the request" do
    evaluation.update!(status: "queued")
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call)
      .and_return(IntentConformance::ShadowEvaluation::ExecuteReviewer::Result.new(success: true, error: nil, evaluation:, executed: 1, failed: 0))

    described_class.perform_now(project.id, evaluation.id)

    expect(IntentConformance::ShadowEvaluation::ExecuteReviewer).to have_received(:call).with(evaluation: evaluation)
    expect(evaluation.reload).to be_running
    expect(evaluation.execution_attempts).to eq(1)
  end

  it "leaves a cancelled queued evaluation untouched" do
    evaluation.update!(status: "cancelled", cancelled_at: Time.current)
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call)

    described_class.perform_now(project.id, evaluation.id)

    expect(IntentConformance::ShadowEvaluation::ExecuteReviewer).not_to have_received(:call)
  end
end
