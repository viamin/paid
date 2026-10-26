# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::CancelExecution do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:evaluation) { create(:intent_conformance_shadow_evaluation, :frozen, project:, solo_maintainer: owner, created_by: owner) }

  it "preserves collected evidence while asking a running worker to stop" do
    evaluation.update!(status: "running")
    evaluation.runs.create!(case_id: "A-01", verdict: "within_scope", reviewer_run_id: "run", reviewer_model: "model",
      prompt_digest: "digest", cost_cents: 42, recorded_at: Time.current)

    result = described_class.call(evaluation:)

    expect(result).to be_success
    expect(evaluation.reload).to be_running
    expect(evaluation.cancel_requested_at).to be_present
    expect(evaluation.runs.find_by!(case_id: "A-01")).to have_attributes(verdict: "within_scope", cost_cents: 42)
  end
end
