# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectDelegation::IntentCheckpoint::Settle do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }
  let(:user) { create(:user, account:) }
  let(:checkpoint) do
    ProjectDelegation::IntentCheckpoint::Plan.call(issue:, questions: [
      {
        "question" => "How long must imported metrics be retained?",
        "affected_scope" => "Data retention policy",
        "recommendation" => "Retain 30 days of imported metrics.",
        "alternatives" => [ "Retain 7 days" ],
        "consequences" => [ "Longer retention increases storage cost." ],
        "evidence" => [ "docs/intent/data-pipeline/design.md" ]
      },
      {
        "question" => "Which cache TTL is allowed?",
        "affected_scope" => "Cache policy",
        "recommendation" => "Use a 5-minute TTL.",
        "consequences" => [ "Longer TTLs serve stale data." ]
      }
    ])
  end

  def revisions_for(issue)
    ProjectDelegation::IntentCheckpoint::Revisions.for(issue)
  end

  it "binds a human's settled answers to the current design and acceptance revision" do  # @spec PROJECT-DELEGATION-002
    settled = described_class.call(checkpoint:, user:, disposition: "settled", answers: {
      "data-retention-policy" => "Retain 30 days.",
      "cache-policy" => "5-minute TTL."
    })

    settled.reload
    expect(settled.status).to eq("settled")
    expect(settled.disposition).to eq("settled")
    expect(settled.answers).to eq(
      "data-retention-policy" => "Retain 30 days.",
      "cache-policy" => "5-minute TTL."
    )
    expect(settled.design_revision).to eq(revisions_for(issue)["design_revision"])
    expect(settled.acceptance_revision).to eq(revisions_for(issue)["acceptance_revision"])
    expect(settled.settled_by).to eq(user)
    expect(settled.settled_at).to be_within(1.second).of(Time.current)
  end

  it "records an audit event for the settlement" do  # @spec PROJECT-DELEGATION-002
    settled = described_class.call(checkpoint:, user:, disposition: "settled", answers: {
      "data-retention-policy" => "Retain 30 days.", "cache-policy" => "5-minute TTL."
    })

    event = AccountActivityEvent.find_by(action: "intent_checkpoint.settled", subject: settled)
    expect(event).to be_present
    expect(event.actor).to eq(user)
    expect(event.metadata).to include(
      "disposition" => "settled",
      "design_revision" => settled.design_revision,
      "acceptance_revision" => settled.acceptance_revision
    )
  end

  it "requires an answer for every group before settling" do  # @spec PROJECT-DELEGATION-002
    expect {
      described_class.call(checkpoint:, user:, disposition: "settled",
        answers: { "data-retention-policy" => "Retain 30 days." })
    }.to raise_error(described_class::InvalidSettlement, /cache-policy/)

    expect(checkpoint.reload.status).to eq("pending")
  end

  it "records a rejection without requiring answers" do  # @spec PROJECT-DELEGATION-002
    rejected = described_class.call(checkpoint:, user:, disposition: "rejected")

    expect(rejected.reload.status).to eq("rejected")
    expect(rejected.disposition).to eq("rejected")
    expect(rejected.design_revision).to eq(revisions_for(issue)["design_revision"])
    expect(rejected.acceptance_revision).to eq(revisions_for(issue)["acceptance_revision"])
  end

  it "records an amendment as a settled disposition that stays immutable" do  # @spec PROJECT-DELEGATION-002
    amended = described_class.call(checkpoint:, user:, disposition: "amended", answers: {
      "data-retention-policy" => "Retain 45 days instead.",
      "cache-policy" => "5-minute TTL."
    })

    expect(amended.reload.status).to eq("settled")
    expect(amended.disposition).to eq("amended")
    expect {
      amended.update!(answers: { "data-retention-policy" => "Retain 90 days.", "cache-policy" => "1-hour TTL." })
    }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "cannot settle a checkpoint twice" do  # @spec PROJECT-DELEGATION-002
    described_class.call(checkpoint:, user:, disposition: "settled", answers: {
      "data-retention-policy" => "Retain 30 days.", "cache-policy" => "5-minute TTL."
    })

    expect {
      described_class.call(checkpoint: checkpoint.reload, user:, disposition: "settled",
        answers: { "data-retention-policy" => "x", "cache-policy" => "y" })
    }.to raise_error(described_class::InvalidSettlement, /pending/)
  end

  it "resolves the Inbox request once the checkpoint is settled" do  # @spec PROJECT-DELEGATION-002
    described_class.call(checkpoint:, user:, disposition: "settled", answers: {
      "data-retention-policy" => "Retain 30 days.", "cache-policy" => "5-minute TTL."
    })

    notification = Notification.find_by(source: ProjectDelegation::IntentCheckpoint::Plan::NOTIFICATION_SOURCE)
    expect(notification.resolved_at).to be_present
  end

  it "resolves the recorded feature-intent decisions it was derived from" do  # @spec PROJECT-DELEGATION-002
    feature_intent = create(:feature_intent, project:)
    create(:feature_intent_issue, feature_intent:, issue:)
    decision = create(:feature_intent_decision, feature_intent:,
      design_claim: "Imported metrics honor a retention policy.",
      prompt: "Should retention apply to existing records or only new ones?")
    derived = ProjectDelegation::IntentCheckpoint::Plan.call(issue:)
    key = derived.groups.first["key"]

    described_class.call(checkpoint: derived, user:, disposition: "settled",
      answers: { key => "New records only." })

    expect(decision.reload.status).to eq("resolved")
    expect(decision.answer).to eq("New records only.")
    expect(decision.resolved_by).to eq(user)
  end
end
