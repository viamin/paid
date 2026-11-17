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

  it "preserves the earlier responder's attribution on already-resolved questions" do
    feature_intent = create(:feature_intent)
    first = create(:feature_intent_decision, feature_intent:)
    second = create(:feature_intent_decision, feature_intent:)
    checkpoint = create(:project_delegation_intent_checkpoint, feature_intent:)
    checkpoint.questions = [ first, second ]
    earlier_actor = create(:user, account: feature_intent.project.account)
    settling_actor = create(:user, account: feature_intent.project.account)
    first_answered_at = 2.hours.ago.change(usec: 0)

    travel_to(first_answered_at) { first.resolve!(by: earlier_actor, answer: "CSV exports only.") }

    described_class.call(
      checkpoint:, actor: settling_actor,
      answers: { first.id => "CSV exports only.", second.id => "Narrow rollout." },
      design_revision: "design-1", acceptance_revision: "acceptance-1"
    )

    expect(first.reload).to have_attributes(resolved_by: earlier_actor, resolved_at: first_answered_at)
    expect(second.reload).to have_attributes(resolved_by: settling_actor, answer: "Narrow rollout.")
    expect(checkpoint.settlements.first.answers).to eq(
      first.id.to_s => "CSV exports only.", second.id.to_s => "Narrow rollout."
    )
  end
end
