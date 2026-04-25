# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::MarkQualityRecoveryActionActivity do
  let(:activity) { described_class.new }

  it "marks the recovery action failed with result details" do
    action = create(:quality_recovery_action, :prompt_evolution, :executing)

    result = activity.execute(
      recovery_action_id: action.id,
      result: { status: "no_candidates" }
    )

    expect(result).to eq(status: :failed, recovery_action_id: action.id)
    expect(action.reload.status).to eq("failed")
    expect(action.result["error"]).to include("status" => "no_candidates")
  end

  it "returns not_found when the recovery action no longer exists" do
    result = activity.execute(recovery_action_id: -1)

    expect(result).to eq(status: :not_found)
  end
end
