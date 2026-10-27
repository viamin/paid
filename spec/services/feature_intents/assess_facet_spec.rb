# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-002 FACET-CONFIDENCE-003 FACET-CONFIDENCE-004
# @spec FACET-CONFIDENCE-012 FACET-CONFIDENCE-013 FACET-CONFIDENCE-014
RSpec.describe FeatureIntents::AssessFacet do
  before { configure_llm_routing(project: facet.feature_intent.project) }
  after { Current.user = nil }

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
    allow(AgentHarness.conductor).to receive(:execute_direct).and_return(response)

    result = described_class.call(assessment:)

    expect(result).to have_attributes(status: "completed", intent_score: 90, technical_score: 75,
      inferred_fit: "Keyboard first directly serves the issue scope.", evidence_references: [ evidence.source_reference ], rubric_version: described_class::RUBRIC_VERSION)
    expect(AgentHarness.conductor).to have_received(:execute_direct).with(a_string_including("human_statement"), hash_including(tools: :none))
  end

  it "fails closed for malformed agent output" do
    allow(AgentHarness.conductor).to receive(:execute_direct).and_return(double(success?: true, output: "not json"))

    expect(described_class.call(assessment:)).to have_attributes(status: "failed", intent_score: nil, technical_score: nil)
  end

  it "rejects output made obsolete by concurrent evidence" do
    allow(AgentHarness.conductor).to receive(:execute_direct) do
      FeatureIntents::IngestFacetEvidence.call(facet:, attributes: {
        idempotency_key: "human-message-2", source_type: "human_statement", source_reference: "chat-message-2",
        statement: "It must also work with touch.", occurred_at: Time.current
      })
      response
    end

    expect(described_class.call(assessment:)).to have_attributes(status: "superseded", intent_score: nil, technical_score: nil)
  end

  it "leaves conflicting collaborators unresolved rather than selecting a majority direction" do
    allow(AgentHarness.conductor).to receive(:execute_direct).and_return(double(success?: true, output: JSON.generate(
      "status" => "clarification_needed", "intent_score" => nil, "technical_score" => 80,
      "inferred_fit" => nil,
      "explanation" => "Collaborators disagree about keyboard-only behavior.", "evidence_references" => [ evidence.source_reference ]
    )))

    result = described_class.call(assessment:)

    expect(result).to have_attributes(status: "unknown", intent_score: nil, technical_score: 80)
    expect(result.explanation).to include("Clarification needed")
  end

  [
    { name: "unknown intent with a successful prototype", intent: nil, technical: 90 },
    { name: "explicit intent with weak technical evidence", intent: 95, technical: 25 }
  ].each do |evaluation_case|
    it "retains the two independent axes for #{evaluation_case[:name]}" do
      status = evaluation_case[:intent].nil? ? "unknown" : "completed"
      allow(AgentHarness.conductor).to receive(:execute_direct).and_return(double(success?: true, output: JSON.generate(
        "status" => status, "intent_score" => evaluation_case[:intent], "technical_score" => evaluation_case[:technical],
        "inferred_fit" => nil,
        "explanation" => evaluation_case[:name], "evidence_references" => [ evidence.source_reference ]
      )))

      result = described_class.call(assessment:)

      expect(result).to have_attributes(status: status, intent_score: evaluation_case[:intent], technical_score: evaluation_case[:technical])
    end
  end
end
