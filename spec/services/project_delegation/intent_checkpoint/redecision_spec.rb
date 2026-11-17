# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-002
RSpec.describe ProjectDelegation::IntentCheckpoint::Redecision do
  it "routes only a design or acceptance revision delta to one focused decision" do
    checkpoint = create(:project_delegation_intent_checkpoint)
    actor = create(:user, account: checkpoint.feature_intent.project.account)
    ProjectDelegation::IntentCheckpoint::Settle.call(
      checkpoint:, actor:, answers: {}, design_revision: "design-1", acceptance_revision: "acceptance-1"
    )

    expect {
      described_class.call(checkpoint:, design_revision: "design-2", acceptance_revision: "acceptance-1")
    }.to change(Notification, :count).by(1)
    expect {
      described_class.call(checkpoint:, design_revision: "design-2", acceptance_revision: "acceptance-1")
    }.not_to change(Notification, :count)
  end
end
