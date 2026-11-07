# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectDelegation::IntentCheckpoint::Plan do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }

  def question(overrides = {})
    {
      "question" => "How long must imported metrics be retained?",
      "affected_scope" => "Data retention policy",
      "recommendation" => "Retain 30 days of imported metrics.",
      "alternatives" => [ "Retain 7 days" ],
      "consequences" => [ "Longer retention increases storage cost." ],
      "evidence" => [ "docs/intent/data-pipeline/design.md" ]
    }.merge(overrides)
  end

  def retention_questions
    [
      question,
      question(
        "question" => "Must retained metrics be anonymized?",
        "recommendation" => "Anonymize after retention expires.",
        "alternatives" => [ "Never anonymize" ],
        "consequences" => [ "Anonymization removes debugging detail." ],
        "evidence" => [ "docs/intent/data-pipeline/security.md" ]
      )
    ]
  end

  it "creates a pending checkpoint presenting every material group" do  # @spec PROJECT-DELEGATION-002
    checkpoint = described_class.call(issue:, questions: [ question ])

    expect(checkpoint.status).to eq("pending")
    expect(checkpoint.project).to eq(project)
    expect(checkpoint.account).to eq(account)
    group = checkpoint.groups.first
    expect(group["questions"]).to eq([ question["question"] ])
    expect(group["recommendation"]).to eq(question["recommendation"])
    expect(group["alternatives"]).to eq([ "Retain 7 days" ])
    expect(group["consequences"]).to eq([ "Longer retention increases storage cost." ])
    expect(group["affected_scope"]).to eq("Data retention policy")
    expect(group["evidence"]).to eq([ "docs/intent/data-pipeline/design.md" ])
  end

  it "groups related questions into one reviewable group" do  # @spec PROJECT-DELEGATION-002
    checkpoint = described_class.call(issue:, questions: retention_questions + [
      question("question" => "Which cache TTL is allowed?", "affected_scope" => "Cache policy")
    ])

    expect(checkpoint.groups.size).to eq(2)
    retention = checkpoint.groups.find { |group| group["affected_scope"] == "Data retention policy" }
    expect(retention["questions"]).to contain_exactly(
      "How long must imported metrics be retained?",
      "Must retained metrics be anonymized?"
    )
    expect(retention["recommendation"]).to eq("Retain 30 days of imported metrics.")
  end

  it "merges the alternatives, consequences, and evidence of a group" do  # @spec PROJECT-DELEGATION-002
    checkpoint = described_class.call(issue:, questions: retention_questions + [
      question("question" => "Which cache TTL is allowed?", "affected_scope" => "Cache policy")
    ])

    retention = checkpoint.groups.find { |group| group["affected_scope"] == "Data retention policy" }
    expect(retention["alternatives"]).to contain_exactly("Retain 7 days", "Never anonymize")
    expect(retention["consequences"]).to contain_exactly(
      "Longer retention increases storage cost.",
      "Anonymization removes debugging detail."
    )
    expect(retention["evidence"]).to contain_exactly(
      "docs/intent/data-pipeline/design.md",
      "docs/intent/data-pipeline/security.md"
    )
  end

  it "uses one stable key per affected scope" do  # @spec PROJECT-DELEGATION-002
    checkpoint = described_class.call(issue:, questions: [
      question,
      question("affected_scope" => "data retention policy"),
      question("question" => "Which cache TTL?", "affected_scope" => "Cache policy")
    ])

    keys = checkpoint.groups.map { |group| group["key"] }
    expect(keys).to contain_exactly("data-retention-policy", "cache-policy")
  end

  it "rejects question payloads without a question or affected scope" do  # @spec PROJECT-DELEGATION-002
    expect { described_class.call(issue:, questions: [ question("question" => "  ") ]) }
      .to raise_error(ArgumentError, /question/)
    expect { described_class.call(issue:, questions: [ question("affected_scope" => "") ]) }
      .to raise_error(ArgumentError, /affected_scope/)
  end

  it "supersedes the prior pending checkpoint instead of stacking reviews" do  # @spec PROJECT-DELEGATION-002
    first = described_class.call(issue:, questions: [ question ])
    second = described_class.call(issue:, questions: [
      question, question("question" => "Which cache TTL?", "affected_scope" => "Cache policy")
    ])

    expect(first.reload.status).to eq("superseded")
    expect(second.status).to eq("pending")
    expect(described_class.pending_for(issue)).to eq(second)
  end

  it "keeps only one pending checkpoint per work item" do  # @spec PROJECT-DELEGATION-002
    described_class.call(issue:, questions: [ question ])

    expect {
      described_class.call(issue:, questions: [ question("affected_scope" => "Cache policy") ])
    }.not_to change { IntentCheckpoint.where(status: "pending").count }
  end

  it "shows the grouped questions with recommendation and consequences in the Inbox" do  # @spec PROJECT-DELEGATION-002
    checkpoint = described_class.call(issue:, questions: [ question ])

    notification = Notification.find_by(source: described_class::NOTIFICATION_SOURCE)
    expect(notification).to be_blocking
    expect(notification.metadata["checkpoint_id"]).to eq(checkpoint.id)
    expect(notification.metadata["groups"]).to contain_exactly(
      hash_including(
        "key" => "data-retention-policy",
        "recommendation" => "Retain 30 days of imported metrics.",
        "consequences" => [ "Longer retention increases storage cost." ]
      )
    )
  end

  it "refreshes the single Inbox request instead of stacking notifications" do  # @spec PROJECT-DELEGATION-002
    described_class.call(issue:, questions: [ question ])
    second = described_class.call(issue:, questions: [
      question, question("question" => "Which cache TTL?", "affected_scope" => "Cache policy")
    ])

    notifications = Notification.where(source: described_class::NOTIFICATION_SOURCE)
    expect(notifications.count).to eq(1)
    expect(notifications.first.metadata["checkpoint_id"]).to eq(second.id)
  end

  describe "deriving questions from recorded RDR-066 decisions" do
    let(:feature_intent) { create(:feature_intent, project:) }

    before { create(:feature_intent_issue, feature_intent:, issue:) }

    it "groups open feature-intent decisions by the design claim they affect" do  # @spec PROJECT-DELEGATION-002
      open_question = create(:feature_intent_decision, feature_intent:,
        design_claim: "Imported metrics honor a retention policy.",
        prompt: "Should retention apply to existing records or only new ones?")
      create(:feature_intent_decision, :inferred_decision, feature_intent:,
        design_claim: "Imported metrics honor a retention policy.",
        prompt: "[inferred] Retention applies to new records only.")
      create(:feature_intent_decision, :resolved, feature_intent:,
        design_claim: "Resolved claim.", prompt: "Already answered?")

      checkpoint = described_class.call(issue:)

      expect(checkpoint.groups.size).to eq(1)
      group = checkpoint.groups.first
      expect(group["questions"]).to contain_exactly(
        "Should retention apply to existing records or only new ones?",
        "[inferred] Retention applies to new records only."
      )
      expect(group["source_decision_ids"]).to contain_exactly(open_question.id, kind_of(Integer))
    end

    it "returns nil when no material questions are known" do  # @spec PROJECT-DELEGATION-002
      expect(described_class.call(issue:)).to be_nil
    end
  end
end
