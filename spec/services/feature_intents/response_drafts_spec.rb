# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-019
RSpec.describe FeatureIntents::ResponseDrafts do
  let(:session) { {} }
  let(:feature_intent) { create(:feature_intent) }
  let(:decision) { create(:feature_intent_decision, feature_intent: feature_intent) }

  def save_draft(answer:, decision_id: decision.id, feature: feature_intent)
    described_class.save(session, feature_intent: feature, decision_id:, answer:)
  end

  it "saves a draft keyed by feature intent and decision and reloads it" do
    save_draft(answer: "Use CSV exports only.")

    expect(described_class.for_feature_intent(session, feature_intent)).to eq(decision.id.to_s => "Use CSV exports only.")
  end

  it "overwrites the same decision's draft on a later submission" do
    save_draft(answer: "First attempt.")
    save_draft(answer: "Corrected attempt.")

    expect(described_class.for_feature_intent(session, feature_intent)).to eq(decision.id.to_s => "Corrected attempt.")
  end

  it "keeps drafts for different feature intents separate" do
    other_feature = create(:feature_intent)
    other_decision = create(:feature_intent_decision, feature_intent: other_feature)

    save_draft(answer: "This feature's draft.")
    save_draft(answer: "Other feature's draft.", decision_id: other_decision.id, feature: other_feature)

    expect(described_class.for_feature_intent(session, feature_intent)).to eq(decision.id.to_s => "This feature's draft.")
    expect(described_class.for_feature_intent(session, other_feature)).to eq(other_decision.id.to_s => "Other feature's draft.")
  end

  it "clears only the saved decision's draft" do
    sibling = create(:feature_intent_decision, feature_intent: feature_intent)
    save_draft(answer: "Keep me.")
    save_draft(answer: "Clear me.", decision_id: sibling.id)

    described_class.clear(session, feature_intent:, decision_id: sibling.id)

    expect(described_class.for_feature_intent(session, feature_intent)).to eq(decision.id.to_s => "Keep me.")
  end

  it "drops the feature bucket once its last draft is cleared" do
    save_draft(answer: "Only draft.")

    described_class.clear(session, feature_intent:, decision_id: decision.id)

    expect(session[described_class::SESSION_KEY]).not_to have_key(feature_intent.id.to_s)
  end

  it "rejects an answer that exceeds the cookie-session limit" do
    expect {
      save_draft(answer: "a" * (described_class::MAX_ANSWER_CHARS + 1))
    }.to raise_error(ArgumentError, "Response draft exceeds #{described_class::MAX_ANSWER_CHARS} characters.")
  end

  it "retains only the most recent drafts across feature intents" do
    decisions = Array.new(described_class::MAX_DRAFTS + 1) do
      create(:feature_intent_decision, feature_intent: create(:feature_intent))
    end

    decisions.each { |draft_decision| save_draft(answer: "Draft #{draft_decision.id}.", decision_id: draft_decision.id, feature: draft_decision.feature_intent) }

    retained = decisions.last(described_class::MAX_DRAFTS)
    dropped = decisions.first
    retained.each do |draft_decision|
      expect(described_class.for_feature_intent(session, draft_decision.feature_intent)).to eq(draft_decision.id.to_s => "Draft #{draft_decision.id}.")
    end
    expect(described_class.for_feature_intent(session, dropped.feature_intent)).to eq({})
  end

  it "retains the newest multibyte draft within the cookie byte budget" do
    decisions = Array.new(described_class::MAX_DRAFTS) do
      create(:feature_intent_decision, feature_intent: create(:feature_intent))
    end
    answer = "あ" * described_class::MAX_ANSWER_CHARS

    decisions.each do |draft_decision|
      save_draft(answer:, decision_id: draft_decision.id, feature: draft_decision.feature_intent)
    end

    expect(described_class.for_feature_intent(session, decisions.last.feature_intent)).to eq(decisions.last.id.to_s => answer)
    expect(session.to_json.bytesize).to be <= described_class::MAX_SERIALIZED_DRAFT_BYTES
  end
end
