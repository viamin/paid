# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-011
RSpec.describe FeatureIntents::CriteriaClarityReview do
  before { configure_llm_routing(project: project)
    allow(Rails.logger).to receive(:warn)
   }

  after { Current.user = nil }

  let(:project) { create(:project) }
  let(:feature_intent) { create(:feature_intent, project: project, brief: "Ship a CSV export button.") }

  def stub_llm(payload, exit_code: 0)
    allow(AgentHarness.conductor).to receive(:execute_direct).and_return(
      AgentHarness::Response.new(
        output: payload.to_json,
        exit_code: exit_code,
        duration: 1.0,
        provider: :claude,
        model: "configured-mid",
        tokens: { input: 10, output: 10, total: 20 }
      )
    )
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
    allow(AgentHarness.conductor).to receive(:execute_direct).and_return(
      AgentHarness::Response.new(
        output: "not json", exit_code: 0, duration: 1.0, provider: :claude,
        model: "configured-mid", tokens: { input: 1, output: 1, total: 2 }
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

    expect(AgentHarness.conductor).to have_received(:execute_direct) do |prompt, **|
      expect(prompt).not_to include("Untrusted issue title")
    end
  end
end
