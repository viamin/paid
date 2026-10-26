# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-022
RSpec.describe FacetConfidence::CorpusRunner do
  let(:project) { create(:project) }
  let(:corpus_path) { Rails.root.join("docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml") }
  let(:ledger_path) { Rails.root.join("tmp/facet-confidence-corpus-runner-#{SecureRandom.uuid}.jsonl") }
  let(:assessor) { class_double(FeatureIntents::AssessFacet) }

  after { File.delete(ledger_path) if File.exist?(ledger_path) }

  it "records unavailable pinned-model calls as provenance-bound operational failures" do
    allow(assessor).to receive(:call) do |assessment:|
      assessment.update!(status: "failed", explanation: "Assessment unavailable (AgentHarness::Unavailable).", assessed_at: Time.current)
    end

    results = described_class.call(project:, corpus_path:, ledger_path:, assessor:)

    expect(results).to all(have_attributes(assessment_status: "failed"))
    events = FacetConfidence::AssessmentCorpusLedger.events(ledger_path)
    expect(events).to all(include("corpus_version" => "facet-confidence-corpus-v1", "rubric_version" => "facet-confidence-v1",
      "model_version" => FeatureIntents::AssessFacet::MODEL_VERSION, "status" => "failed"))
    expect(events.map { |event| event.fetch("input_revision") }).to all(be_positive)
    expect(FacetConfidence::AssessmentOutcomeReport.metrics(corpus_path:, ledger_path:).fetch(:coverage)).to eq(assessed: 0, total: 8)
  end
end
