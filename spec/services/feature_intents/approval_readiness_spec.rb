# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-011
RSpec.describe FeatureIntents::ApprovalReadiness do
  let(:feature_intent) { create(:feature_intent, :ready_for_approval) }

  it "is ready when there are no open decisions, no stale heads, and clear criteria" do
    create(:feature_intent_design_pr, feature_intent: feature_intent)

    result = described_class.call(feature_intent: feature_intent)

    expect(result).to be_ready
    expect(result.blockers).to be_empty
  end

  it "blocks on an unresolved question" do
    create(:feature_intent_decision, feature_intent: feature_intent, kind: "question")

    result = described_class.call(feature_intent: feature_intent)

    expect(result).not_to be_ready
    expect(result.blockers.map(&:code)).to include("unresolved_questions")
  end

  it "blocks on an unconfirmed inferred decision" do
    create(:feature_intent_decision, :inferred_decision, feature_intent: feature_intent)

    result = described_class.call(feature_intent: feature_intent)

    expect(result).not_to be_ready
    expect(result.blockers.map(&:code)).to include("unconfirmed_inferred_decisions")
  end

  it "does not block on a resolved question" do
    create(:feature_intent_decision, :resolved, feature_intent: feature_intent, kind: "question")

    result = described_class.call(feature_intent: feature_intent)

    expect(result).to be_ready
  end

  it "blocks on a stale required design PR head" do
    create(:feature_intent_design_pr, :stale, feature_intent: feature_intent, required: true)

    result = described_class.call(feature_intent: feature_intent)

    expect(result).not_to be_ready
    expect(result.blockers.map(&:code)).to include("stale_design_prs")
  end

  it "does not block on a stale but non-required design PR head" do
    create(:feature_intent_design_pr, :stale, feature_intent: feature_intent, required: false)

    result = described_class.call(feature_intent: feature_intent)

    expect(result).to be_ready
  end

  it "blocks on vague acceptance criteria" do
    feature_intent.update!(criteria_clarity_state: "vague", criteria_clarity_explanation: "No concrete criteria.")

    result = described_class.call(feature_intent: feature_intent)

    expect(result).not_to be_ready
    blocker = result.blockers.find { |b| b.code == "vague_acceptance_criteria" }
    expect(blocker.message).to eq("No concrete criteria.")
  end

  it "blocks when criteria clarity has never been evaluated" do
    feature_intent.update!(criteria_clarity_state: "pending")

    result = described_class.call(feature_intent: feature_intent)

    expect(result).not_to be_ready
    expect(result.blockers.map(&:code)).to include("vague_acceptance_criteria")
  end

  it "reports every applicable blocker at once" do
    create(:feature_intent_decision, feature_intent: feature_intent, kind: "question")
    create(:feature_intent_decision, :inferred_decision, feature_intent: feature_intent)
    feature_intent.update!(criteria_clarity_state: "vague")

    result = described_class.call(feature_intent: feature_intent)

    expect(result.blockers.map(&:code)).to contain_exactly(
      "unresolved_questions", "unconfirmed_inferred_decisions", "vague_acceptance_criteria"
    )
  end

  it "blocks when the feature status is not approvable (e.g. discovering)" do
    feature_intent.update!(status: "discovering", criteria_clarity_state: "clear")

    result = described_class.call(feature_intent: feature_intent)

    expect(result).not_to be_ready
    blocker = result.blockers.find { |b| b.code == "not_approvable_status" }
    expect(blocker.message).to include("discovering")
  end

  it "is ready for every APPROVABLE_STATUSES status when other checks pass" do
    FeatureIntent::APPROVABLE_STATUSES.each do |status|
      feature_intent.update!(status: status)

      result = described_class.call(feature_intent: feature_intent)

      expect(result).to be_ready, "expected #{status} to be ready but got blockers: #{result.blockers.map(&:code)}"
    end
  end
end
