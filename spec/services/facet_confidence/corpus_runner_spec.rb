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
    allow(FeatureIntents::AssessFacet).to receive(:new) do |assessment:|
      instance_double(FeatureIntents::AssessFacet, cost_cents: 17, call: instance_double(FeatureIntentFacetAssessment,
        status: "completed", intent_score: 80, technical_score: 80,
        evidence_references: assessment.feature_intent_facet_direction.evidence.where(superseded_by: nil).pluck(:source_reference).first(1)))
    end

    events = described_class.call(project:, ledger_path: ledger)

    expect(events).to all(include(
      "type" => "assessment_run",
      "rubric_version" => FeatureIntents::AssessFacet::RUBRIC_VERSION,
      "model_version" => FeatureIntents::AssessFacet::MODEL_VERSION
    ))
    expect(events.count).to eq(8)
    expect(events).to all(include("cost_cents" => 17))
    expect(FacetConfidence::AssessmentCorpusLedger.validate!(
      corpus_path: described_class::CORPUS_PATH,
      ledger_path: ledger
    )).to be(true)
    expect(FeatureIntents::AssessFacet).to have_received(:new).exactly(8).times
  end

  it "passes each frozen actor role into the assessor's active evidence" do
    assessed_contexts = []
    allow(FeatureIntents::AssessFacet).to receive(:new) do |assessment:|
      assessed_contexts.concat(assessment.feature_intent_facet_direction.evidence.pluck(:textual_context))
      instance_double(FeatureIntents::AssessFacet, cost_cents: 17, call: instance_double(FeatureIntentFacetAssessment,
        status: "completed", intent_score: 80, technical_score: 80,
        evidence_references: assessment.feature_intent_facet_direction.evidence.where(superseded_by: nil).pluck(:source_reference).first(1)))
    end

    described_class.call(project:, ledger_path: ledger)

    expect(assessed_contexts).to include("Corpus actor role: owner.", "Corpus actor role: collaborator.")
  end

  it "rejects a corpus pinned to a different assessor model before dispatching" do
    stub_const("FeatureIntents::AssessFacet::MODEL_VERSION", "claude-sonnet-newer")
    allow(FeatureIntents::AssessFacet).to receive(:new)

    expect { described_class.call(project:, ledger_path: ledger) }
      .to raise_error(described_class::PinnedModelMismatch, /claude-sonnet-4-6.*claude-sonnet-newer/)

    expect(FeatureIntents::AssessFacet).not_to have_received(:new)
  end

  it "retries a failed provider attempt and records the failed run it replaces" do
    failed_event = failed_run_event
    FacetConfidence::AssessmentCorpusLedger.append!(ledger_path: ledger, corpus_path: described_class::CORPUS_PATH, event: failed_event)
    allow(FeatureIntents::AssessFacet).to receive(:new) do |assessment:|
      instance_double(FeatureIntents::AssessFacet, cost_cents: 17, call: instance_double(FeatureIntentFacetAssessment,
        status: "completed", intent_score: 80, technical_score: 80,
        evidence_references: assessment.feature_intent_facet_direction.evidence.where(superseded_by: nil).pluck(:source_reference).first(1)))
    end

    events = described_class.call(project:, ledger_path: ledger)

    expect(events.find { |event| event["case_id"] == failed_event.fetch("case_id") })
      .to include("retry_of_event_id" => failed_event.fetch("event_id"))
    expect(FacetConfidence::AssessmentCorpusLedger.validate!(
      corpus_path: described_class::CORPUS_PATH,
      ledger_path: ledger
    )).to be(true)
  end

  it "records a zero-cost failed provider attempt so the next run can retry it" do
    allow(FeatureIntents::AssessFacet).to receive(:new) do
      instance_double(FeatureIntents::AssessFacet, cost_cents: nil, call: instance_double(FeatureIntentFacetAssessment,
        status: "failed", intent_score: nil, technical_score: nil, evidence_references: []))
    end

    failed_events = described_class.call(project:, ledger_path: ledger)

    expect(failed_events).to all(include("status" => "failed", "cost_cents" => 0))
    expect(failed_events.map { |event| event["retry_of_event_id"] }).to all(be_nil)

    allow(FeatureIntents::AssessFacet).to receive(:new) do |assessment:|
      instance_double(FeatureIntents::AssessFacet, cost_cents: 17, call: instance_double(FeatureIntentFacetAssessment,
        status: "completed", intent_score: 80, technical_score: 80,
        evidence_references: assessment.feature_intent_facet_direction.evidence.where(superseded_by: nil).pluck(:source_reference).first(1)))
    end

    retried_events = described_class.call(project:, ledger_path: ledger)

    expect(retried_events).to all(include("cost_cents" => 17))
    expect(retried_events.map { |event| event.fetch("retry_of_event_id") }).to match_array(failed_events.map { |event| event.fetch("event_id") })
    expect(FacetConfidence::AssessmentCorpusLedger.validate!(
      corpus_path: described_class::CORPUS_PATH,
      ledger_path: ledger
    )).to be(true)
  end

  it "does not record a zero-cost run when provider cost provenance is unavailable" do
    allow(FeatureIntents::AssessFacet).to receive(:new) do |assessment:|
      instance_double(FeatureIntents::AssessFacet, cost_cents: nil, call: instance_double(FeatureIntentFacetAssessment,
        status: "completed", intent_score: 80, technical_score: 80,
        evidence_references: assessment.feature_intent_facet_direction.evidence.where(superseded_by: nil).pluck(:source_reference).first(1)))
    end

    expect { described_class.call(project:, ledger_path: ledger) }
      .to raise_error(described_class::CostUnavailable, "assessment cost provenance is unavailable")
    expect(FacetConfidence::AssessmentCorpusLedger.events(ledger)).to be_empty
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
