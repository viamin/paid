# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# @spec FACET-CONFIDENCE-016 @spec FACET-CONFIDENCE-017 @spec FACET-CONFIDENCE-018
RSpec.describe FacetConfidence::CorpusRunner do
  let(:project) { create(:project) }
  let(:directory) { Pathname.new(Dir.mktmpdir) }
  let(:ledger) { directory.join("ledger.jsonl") }

  after { directory.rmtree }

  it "runs every unrecorded frozen case through the shipped assessor and records pinned provenance" do
    allow(FeatureIntents::AssessFacet).to receive(:call) do |assessment:|
      instance_double(FeatureIntentFacetAssessment,
        status: "completed", intent_score: 80, technical_score: 80,
        evidence_references: assessment.feature_intent_facet_direction.evidence.where(superseded_by: nil).pluck(:source_reference).first(1))
    end

    events = described_class.call(project:, ledger_path: ledger)

    expect(events).to all(include(
      "type" => "assessment_run",
      "rubric_version" => FeatureIntents::AssessFacet::RUBRIC_VERSION,
      "model_version" => FeatureIntents::AssessFacet::MODEL_VERSION
    ))
    expect(events.count).to eq(8)
    expect(FacetConfidence::AssessmentCorpusLedger.validate!(
      corpus_path: described_class::CORPUS_PATH,
      ledger_path: ledger
    )).to be(true)
    expect(FeatureIntents::AssessFacet).to have_received(:call).exactly(8).times
  end

  it "retries a failed provider attempt and records the failed run it replaces" do
    failed_event = failed_run_event
    FacetConfidence::AssessmentCorpusLedger.append!(ledger_path: ledger, corpus_path: described_class::CORPUS_PATH, event: failed_event)
    allow(FeatureIntents::AssessFacet).to receive(:call) do |assessment:|
      instance_double(FeatureIntentFacetAssessment,
        status: "completed", intent_score: 80, technical_score: 80,
        evidence_references: assessment.feature_intent_facet_direction.evidence.where(superseded_by: nil).pluck(:source_reference).first(1))
    end

    events = described_class.call(project:, ledger_path: ledger)

    expect(events.find { |event| event["case_id"] == failed_event.fetch("case_id") })
      .to include("retry_of_event_id" => failed_event.fetch("event_id"))
    expect(FacetConfidence::AssessmentCorpusLedger.validate!(
      corpus_path: described_class::CORPUS_PATH,
      ledger_path: ledger
    )).to be(true)
  end

  def failed_run_event
    corpus_case = FacetConfidence::AssessmentCorpusLedger.load_corpus(described_class::CORPUS_PATH).first
    { "event_id" => "failed-#{corpus_case.fetch('id')}", "recorded_at" => "2026-10-26T09:00:00Z",
      "type" => "assessment_run", "case_id" => corpus_case.fetch("id"),
      "rubric_version" => corpus_case.fetch("rubric_version"), "model_version" => corpus_case.fetch("model_version"),
      "input_revision" => corpus_case.fetch("evidence_revision"), "status" => "failed",
      "intent_score" => nil, "technical_score" => nil, "evidence_references" => [], "cost_cents" => 0 }
  end
end
