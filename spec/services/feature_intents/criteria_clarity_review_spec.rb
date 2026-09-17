# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-011
RSpec.describe FeatureIntents::CriteriaClarityReview do
  let(:project) { create(:project) }
  let(:feature_intent) { create(:feature_intent, project: project, brief: "Ship a CSV export button.") }

  def stub_llm(payload, exit_code: 0)
    allow(AgentHarness).to receive(:send_message).and_return(
      AgentHarness::Response.new(
        output: payload.to_json,
        exit_code: exit_code,
        duration: 1.0,
        provider: :claude,
        model: "claude-sonnet-4-6",
        tokens: { input: 10, output: 10, total: 20 }
      )
    )
  end

  before do
    allow(Llm::TextMode).to receive(:options).and_return({})
    allow(Rails.logger).to receive(:warn)
  end

  it "returns a clear verdict citing an explanation" do
    stub_llm({ "confidence" => 0.9, "clear" => true, "explanation" => "Criteria name the exact export format." })

    result = described_class.call(feature_intent: feature_intent)

    expect(result).to be_clear
    expect(result.confidence).to eq(0.9)
  end

  it "returns a vague verdict with an explanation" do
    stub_llm({ "confidence" => 0.9, "clear" => false, "explanation" => "\"Handle edge cases\" is not checkable." })

    result = described_class.call(feature_intent: feature_intent)

    expect(result).not_to be_clear
    expect(result.explanation).to eq("\"Handle edge cases\" is not checkable.")
  end

  it "fails closed (nil) when the review is unsuccessful" do
    stub_llm({ "clear" => true }, exit_code: 1)

    expect(described_class.call(feature_intent: feature_intent)).to be_nil
  end

  it "fails closed when the output is not valid JSON" do
    allow(AgentHarness).to receive(:send_message).and_return(
      AgentHarness::Response.new(
        output: "not json", exit_code: 0, duration: 1.0, provider: :claude,
        model: "claude-sonnet-4-6", tokens: { input: 1, output: 1, total: 2 }
      )
    )

    expect(described_class.call(feature_intent: feature_intent)).to be_nil
  end

  it "fails closed when confidence is below the floor" do
    stub_llm({ "confidence" => 0.2, "clear" => true, "explanation" => "Guess." })

    expect(described_class.call(feature_intent: feature_intent)).to be_nil
  end

  it "fails closed when clear is not a boolean" do
    stub_llm({ "confidence" => 0.9, "clear" => "yes", "explanation" => "?" })

    expect(described_class.call(feature_intent: feature_intent)).to be_nil
  end

  it "excludes untrusted linked issues from the prompt" do
    untrusted_issue = create(:issue, project: project, github_creator_login: "totally-not-trusted", title: "Untrusted issue title")
    create(:feature_intent_issue, feature_intent: feature_intent, issue: untrusted_issue)
    stub_llm({ "confidence" => 0.9, "clear" => true, "explanation" => "Fine." })

    described_class.call(feature_intent: feature_intent)

    expect(AgentHarness).to have_received(:send_message) do |prompt, **|
      expect(prompt).not_to include("Untrusted issue title")
    end
  end
end
