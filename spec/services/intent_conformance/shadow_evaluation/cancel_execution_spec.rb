# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::CancelExecution do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, project:, created_by: owner, solo_maintainer: owner,
      status: "queued", labels_frozen_at: Time.current)
  end

  it "cancels queued work without discarding existing case evidence" do
    evaluation.runs.create!(case_id: "A-01", verdict: "within_scope", reviewer_run_id: "r1", reviewer_model: "m",
      prompt_digest: "d", cost_cents: 11, recorded_at: Time.current)

    result = described_class.call(evaluation:)

    expect(result).to be_success
    expect(evaluation.reload).to be_cancelled
    expect(evaluation.execution_cancel_requested).to be(true)
    expect(evaluation.runs.find_by!(case_id: "A-01").cost_cents).to eq(11)
  end
end
