# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-017 FACET-CONFIDENCE-018
RSpec.describe FacetConfidence::RunCorpus do
  let(:project) { create(:project) }
  let(:ledger) { Pathname.new(Dir.mktmpdir).join("ledger.jsonl") }

  after { ledger.dirname.rmtree if ledger.dirname.exist? }

  it "records one provenance-complete operational failure per case when the pinned provider is unavailable" do
    allow(AgentHarness).to receive(:send_message).and_raise(AgentHarness::ConfigurationError, "pinned model unavailable")

    events = described_class.call(project_id: project.id, ledger_path: ledger)

    expect(events).to all(include("status" => "failed", "rubric_version" => "facet-confidence-v1",
      "model_version" => "claude-sonnet-4-6"))
    expect(events.length).to eq(8)
    expect(FacetConfidence::AssessmentCorpusLedger.validate!(corpus_path: described_class::CORPUS_PATH, ledger_path: ledger)).to be(true)
  end
end
