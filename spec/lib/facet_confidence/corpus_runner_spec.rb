# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

require Rails.root.join("lib/facet_confidence/corpus_runner")

# @spec FACET-CONFIDENCE-017 FACET-CONFIDENCE-018
RSpec.describe FacetConfidence::CorpusRunner, :no_db do
  let(:corpus) { Rails.root.join("docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml") }
  let(:directory) { Pathname.new(Dir.mktmpdir) }
  let(:ledger) { directory.join("ledger.jsonl") }
  let(:harness) { double }

  after { directory.rmtree }

  it "records a provenance-complete pinned-model verdict" do
    allow(harness).to receive(:send_message) do |prompt, **|
      response_for(prompt)
    end

    result = described_class.call(corpus_path: corpus, ledger_path: ledger, agent_harness: harness,
      recorded_at: -> { Time.utc(2026, 10, 26) })

    expect(result).to have_attributes(attempted: 8, completed: 8, failed: 0)
    events = FacetConfidence::AssessmentCorpusLedger.events(ledger)
    expect(events).to all(include("corpus_version" => "facet-confidence-corpus-v1", "rubric_version" => "facet-confidence-v1",
      "model_version" => "claude-sonnet-4-6"))
  end

  it "records an unavailable pinned model as an operational failure" do
    allow(harness).to receive(:send_message).and_raise(AgentHarness::Error, "model unavailable")

    result = described_class.call(corpus_path: corpus, ledger_path: ledger, agent_harness: harness)

    expect(result).to have_attributes(attempted: 8, completed: 0, failed: 8)
    expect(FacetConfidence::AssessmentCorpusLedger.events(ledger)).to all(include("status" => "failed", "model_version" => "claude-sonnet-4-6"))
  end

  def response_for(prompt)
    corpus_case = JSON.parse(prompt.split("Corpus case: ").last)
    evidence = corpus_case.fetch("evidence")
    cited_evidence = evidence.find { |item| item["source_type"] == "human_correction" } || evidence.first
    payload = { status: "completed", intent_score: 80, technical_score: 80,
                evidence_references: [ cited_evidence.fetch("reference") ] }.to_json
    Struct.new(:output, :cost_cents) { def success? = true }.new(payload, 7)
  end
end
