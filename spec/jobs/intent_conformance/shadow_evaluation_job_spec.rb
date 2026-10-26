# frozen_string_literal: true

require "rails_helper"

RSpec.describe IntentConformance::ShadowEvaluationJob do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:evaluation) { create(:intent_conformance_shadow_evaluation, :frozen, project: project, solo_maintainer: owner, created_by: owner) }

  it "marks an interrupted execution failed so an operator can retry" do # @spec INTENT-CONFORMANCE-ROLLOUT-011
    evaluation.update!(status: "queued")
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call).and_raise(Timeout::Error, "provider timed out")

    expect { described_class.perform_now(project.id, evaluation.id) }.to raise_error(Timeout::Error)

    expect(evaluation.reload).to have_attributes(status: "failed", last_failure_reason: "provider timed out")
  end

  it "does not execute a cancelled request" do # @spec INTENT-CONFORMANCE-ROLLOUT-011
    evaluation.update!(status: "cancelled", cancelled_at: Time.current)
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call)

    described_class.perform_now(project.id, evaluation.id)

    expect(IntentConformance::ShadowEvaluation::ExecuteReviewer).not_to have_received(:call)
  end
end
