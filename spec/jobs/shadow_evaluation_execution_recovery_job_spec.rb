# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-009
RSpec.describe ShadowEvaluationExecutionRecoveryJob do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:evaluation) { create(:intent_conformance_shadow_evaluation, :frozen, project:, solo_maintainer: owner, created_by: owner) }

  it "recovers a lost worker without deleting collected case evidence" do
    evaluation.update!(status: "running", execution_requested_at: 11.minutes.ago, execution_heartbeat_at: 11.minutes.ago)
    evaluation.runs.create!(case_id: "A-01", verdict: "within_scope", reviewer_run_id: "r1", reviewer_model: "m",
      prompt_digest: "d", cost_cents: 42, recorded_at: Time.current)

    described_class.perform_now(project.id, evaluation.id)

    expect(evaluation.reload).to be_failed
    expect(evaluation.runs.find_by(case_id: "A-01")).to be_evaluated
    expect(evaluation.last_failure_reason).to include("worker stopped")
  end
end
