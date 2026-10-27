# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-002 FACET-CONFIDENCE-003 FACET-CONFIDENCE-004 FACET-CONFIDENCE-017
# @spec FACET-CONFIDENCE-012 FACET-CONFIDENCE-013 FACET-CONFIDENCE-014
RSpec.describe FeatureIntents::AssessFacet do
  let(:direction) { create(:feature_intent_facet_direction) }
  let(:facet) { direction.feature_intent_facet }
  let!(:evidence) do
    FeatureIntents::IngestFacetEvidence.call(facet:, attributes: {
      idempotency_key: "human-message-1", source_type: "human_statement",
      source_reference: "chat-message-1", statement: "Keyboard navigation is required.",
      occurred_at: Time.current, feature_intent_facet_direction: direction
    })
  end
  let(:assessment) do
    create(:feature_intent_facet_assessment, feature_intent_facet_direction: direction,
      evidence_revision: facet.evidence_revision, status: "pending")
  end
  let(:response) do
    double(success?: true, output: JSON.generate(
      "status" => "completed", "intent_score" => 90, "technical_score" => 75,
      "inferred_fit" => "Keyboard first directly serves the issue scope.",
      "explanation" => "The explicit keyboard requirement is clear; feasibility needs prototype evidence.",
      "evidence_references" => [ evidence.source_reference ]
    ))
  end

  it "persists independently scored, cited assessment output through agent_harness" do
    allow(AgentHarness).to receive(:send_message).and_return(response)

    result = described_class.call(assessment:)

    expect(result).to have_attributes(status: "completed", intent_score: 90, technical_score: 75,
      inferred_fit: "Keyboard first directly serves the issue scope.", evidence_references: [ evidence.source_reference ], rubric_version: described_class::RUBRIC_VERSION)
    expect(AgentHarness).to have_received(:send_message).with(a_string_including("human_statement"), hash_including(tools: :none))
  end

  it "exposes attributable evidence context and derives cost from the Claude text response usage" do
    evidence.update!(textual_context: "Corpus actor role: collaborator.")
    response_with_cost = AgentHarness::Response.new(
      output: response.output,
      exit_code: 0,
      duration: 0.1,
      provider: :claude,
      model: described_class::MODEL_VERSION,
      tokens: { input: 1_200, output: 800 },
      metadata: { transport: :http, headers: {} }
    )
    allow(AgentHarness).to receive(:send_message).and_return(response_with_cost)

    assessor = described_class.new(assessment:)
    assessor.call

    expect(AgentHarness).to have_received(:send_message).with(a_string_including("actor_context", "collaborator"), anything)
    expect(assessor.cost_cents).to eq(TokenUsageTracker.calculate_cost(1_200, 800, llm_model: described_class::MODEL_VERSION))
  end

  it "fails closed for malformed agent output" do
    allow(AgentHarness).to receive(:send_message).and_return(double(success?: true, output: "not json"))

    expect(described_class.call(assessment:)).to have_attributes(status: "failed", intent_score: nil, technical_score: nil)
  end

  it "rejects output made obsolete by concurrent evidence" do
    allow(AgentHarness).to receive(:send_message) do
      FeatureIntents::IngestFacetEvidence.call(facet:, attributes: {
        idempotency_key: "human-message-2", source_type: "human_statement", source_reference: "chat-message-2",
        statement: "It must also work with touch.", occurred_at: Time.current
      })
      response
    end

    expect(described_class.call(assessment:)).to have_attributes(status: "superseded", intent_score: nil, technical_score: nil)
  end

  it "leaves conflicting collaborators unresolved rather than selecting a majority direction" do
    allow(AgentHarness).to receive(:send_message).and_return(double(success?: true, output: JSON.generate(
      "status" => "clarification_needed", "intent_score" => nil, "technical_score" => 80,
      "inferred_fit" => nil,
      "explanation" => "Collaborators disagree about keyboard-only behavior.", "evidence_references" => [ evidence.source_reference ]
    )))

    result = described_class.call(assessment:)

    expect(result).to have_attributes(status: "unknown", intent_score: nil, technical_score: 80)
    expect(result.explanation).to include("Clarification needed")
  end

  it "retains the validated rubric verdict when persistence maps clarification to unknown" do
    allow(AgentHarness).to receive(:send_message).and_return(double(success?: true, output: JSON.generate(
      "status" => "clarification_needed", "intent_score" => nil, "technical_score" => 80,
      "inferred_fit" => nil, "explanation" => "Collaborators disagree.",
      "evidence_references" => [ evidence.source_reference ]
    )))

    assessor = described_class.new(assessment:)
    assessor.call

    expect(assessor.response_status).to eq("clarification_needed")
  end

  [
    { name: "unknown intent with a successful prototype", intent: nil, technical: 90 },
    { name: "explicit intent with weak technical evidence", intent: 95, technical: 25 }
  ].each do |evaluation_case|
    it "retains the two independent axes for #{evaluation_case[:name]}" do
      status = evaluation_case[:intent].nil? ? "unknown" : "completed"
      allow(AgentHarness).to receive(:send_message).and_return(double(success?: true, output: JSON.generate(
        "status" => status, "intent_score" => evaluation_case[:intent], "technical_score" => evaluation_case[:technical],
        "inferred_fit" => nil,
        "explanation" => evaluation_case[:name], "evidence_references" => [ evidence.source_reference ]
      )))

      result = described_class.call(assessment:)

      expect(result).to have_attributes(status: status, intent_score: evaluation_case[:intent], technical_score: evaluation_case[:technical])
    end
  end
end
