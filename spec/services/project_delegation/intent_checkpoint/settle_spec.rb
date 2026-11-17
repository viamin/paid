# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-002
RSpec.describe ProjectDelegation::IntentCheckpoint::Settle do
  it "records an immutable human settlement bound to exact revisions" do
    feature_intent = create(:feature_intent)
    question = create(:feature_intent_decision, feature_intent:)
    checkpoint = create(:project_delegation_intent_checkpoint, feature_intent:)
    question.update!(intent_checkpoint: checkpoint)
    actor = create(:user, account: feature_intent.project.account)

    settlement = described_class.call(
      checkpoint:, actor:, answers: { question.id => "Narrow rollout." },
      design_revision: "design-7", acceptance_revision: "acceptance-3"
    )

    expect(settlement).to have_attributes(
      disposition: "settled", settled_by: actor, design_revision: "design-7", acceptance_revision: "acceptance-3"
    )
    expect(checkpoint.reload).to be_settled
    expect(question.reload.status).to eq("resolved")
    expect { settlement.update!(answers: { question.id => "Changed" }) }
      .to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "rejects partial settlement answers" do
    feature_intent = create(:feature_intent)
    first = create(:feature_intent_decision, feature_intent:)
    second = create(:feature_intent_decision, feature_intent:)
    checkpoint = create(:project_delegation_intent_checkpoint, feature_intent:)
    checkpoint.questions = [ first, second ]
    actor = create(:user, account: feature_intent.project.account)

    expect {
      described_class.call(checkpoint:, actor:, answers: { first.id => "Only one." },
        design_revision: "design-1", acceptance_revision: "acceptance-1")
    }.to raise_error(ArgumentError, /Every checkpoint question/)
  end
end
