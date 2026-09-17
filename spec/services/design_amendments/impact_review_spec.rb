# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-AMENDMENT-005
RSpec.describe DesignAmendments::ImpactReview do
  let(:project) { create(:project) }
  let(:feature) { create(:feature_intent, project: project) }
  let(:amendment) do
    create(:design_amendment, feature_intent: feature, project: project,
      drift_evidence: { "changed_claims" => [ "Claim A: verdicts bind to PR head", "Claim B: exceptions stay bounded" ] })
  end
  let(:open_pr) { create(:issue, :pull_request, project: project) }
  let(:unstarted) { create(:issue, project: project, paid_state: "new") }
  let(:merged_pr) { create(:issue, :pull_request, project: project, github_state: "closed", pr_review_phase: "merged") }
  let(:branches) do
    [
      { issue: open_pr, kind: "open_pr" },
      { issue: unstarted, kind: "unstarted_issue" },
      { issue: merged_pr, kind: "merged_pr" }
    ]
  end

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

  it "maps each branch to a terminal outcome citing provided claims" do
    stub_llm({
      "confidence" => 0.9,
      "branches" => [
        { "id" => open_pr.id.to_s, "impact" => "affected",
          "cited_claims" => [ "Claim A: verdicts bind to PR head" ],
          "explanation" => "The PR implements the old head-binding rule." },
        { "id" => unstarted.id.to_s, "impact" => "unaffected", "cited_claims" => [],
          "explanation" => "Unrelated area." },
        { "id" => merged_pr.id.to_s, "impact" => "unaffected", "cited_claims" => [],
          "explanation" => "Merged earlier on separate claims." }
      ]
    })

    result = described_class.call(amendment: amendment, branches: branches)

    expect(result.mapping[open_pr.id][:impact]).to eq("affected")
    expect(result.mapping[unstarted.id][:impact]).to eq("unaffected")
    expect(result.mapping[merged_pr.id][:impact]).to eq("unaffected")
    expect(result.mapping[open_pr.id][:cited_claims]).to eq([ "Claim A: verdicts bind to PR head" ])
  end

  it "fails closed (nil) when the review is unsuccessful" do
    stub_llm({ "branches" => [] }, exit_code: 1)

    expect(described_class.call(amendment: amendment, branches: branches)).to be_nil
  end

  it "fails closed when the output is not valid JSON" do
    allow(AgentHarness).to receive(:send_message).and_return(
      AgentHarness::Response.new(
        output: "not json at all",
        exit_code: 0,
        duration: 1.0,
        provider: :claude,
        model: "claude-sonnet-4-6",
        tokens: { input: 1, output: 1, total: 2 }
      )
    )

    expect(described_class.call(amendment: amendment, branches: branches)).to be_nil
  end

  it "fails closed when a cited claim was not provided" do
    stub_llm({
      "confidence" => 0.9,
      "branches" => [
        { "id" => open_pr.id.to_s, "impact" => "affected", "cited_claims" => [ "Fabricated claim" ],
          "explanation" => "Hallucinated." }
      ]
    })

    expect(described_class.call(amendment: amendment, branches: branches)).to be_nil
  end

  it "fails closed when confidence is below the floor" do
    stub_llm({
      "confidence" => 0.2,
      "branches" => [
        { "id" => open_pr.id.to_s, "impact" => "unaffected", "cited_claims" => [], "explanation" => "Guess." }
      ]
    })

    expect(described_class.call(amendment: amendment, branches: branches)).to be_nil
  end

  it "fails closed when an impact is outside the outcome enum" do
    stub_llm({
      "confidence" => 0.9,
      "branches" => [
        { "id" => open_pr.id.to_s, "impact" => "probably_fine", "cited_claims" => [], "explanation" => "?" }
      ]
    })

    expect(described_class.call(amendment: amendment, branches: branches)).to be_nil
  end

  it "marks branches the reviewer omitted as uncertain" do
    stub_llm({
      "confidence" => 0.9,
      "branches" => [
        { "id" => open_pr.id.to_s, "impact" => "affected",
          "cited_claims" => [ "Claim B: exceptions stay bounded" ],
          "explanation" => "Implements the bounded-exception rule." }
      ]
    })

    result = described_class.call(amendment: amendment, branches: branches)

    expect(result.mapping[unstarted.id][:impact]).to eq("uncertain")
    expect(result.mapping[merged_pr.id][:impact]).to eq("uncertain")
  end
end
