# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-022
RSpec.describe FacetConfidence::AssessmentCorpusRunner do
  let(:project) { create(:project) }
  let(:corpus_path) { Rails.root.join(described_class::DEFAULT_CORPUS_PATH) }
  let(:ledger_path) { Rails.root.join("tmp/facet-confidence-ledger-#{SecureRandom.hex(4)}.jsonl") }

  after { FileUtils.rm_f(ledger_path) }

  def corpus_case(case_id)
    FacetConfidence::Corpus.new(path: corpus_path.to_s).find_case(case_id)
  end

  # The stub cites the references the shipped prompt offers, so the recorded
  # run satisfies the ledger's citation rules for the case under assessment.
  def stub_assessment(model: "claude-sonnet-4-6", status: "completed", intent_score: 90, technical_score: 90, cost_cents: 3)
    allow(AgentHarness).to receive(:send_message) do |prompt, **_options|
      references = prompt.scan(/"reference":"([^"]+)"/).flatten
      double(success?: true, model: model, metadata: { cost_cents: cost_cents }, output: JSON.generate(
        "status" => status, "intent_score" => intent_score, "technical_score" => technical_score,
        "inferred_fit" => nil, "explanation" => "Corpus measurement run.",
        "evidence_references" => references
      ))
    end
  end

  def ledger_events
    File.readlines(ledger_path).map { |line| JSON.parse(line) }
  end

  def metrics
    FacetConfidence::AssessmentOutcomeReport.metrics(corpus_path: corpus_path.to_s, ledger_path: ledger_path.to_s)
  end

  it "records a provenance-complete run for every corpus case and compiles the measured outcomes" do
    stub_assessment

    result = described_class.call(project: project, corpus_path: corpus_path.to_s, ledger_path: ledger_path.to_s)

    expect(result).to have_attributes(success: true)
    expect(result.recorded.length).to eq(8)
    expect(result.refused).to be_empty
    events = ledger_events
    expect(events.length).to eq(8)
    expect(events.map { |event| event.fetch("case_id") }).to contain_exactly(
      "FC-CORPUS-01", "FC-CORPUS-02", "FC-CORPUS-03", "FC-CORPUS-04",
      "FC-CORPUS-05", "FC-CORPUS-06", "FC-CORPUS-07", "FC-CORPUS-08"
    )
    expect(events.first).to include("rubric_version" => "facet-confidence-v1", "model_version" => "claude-sonnet-4-6",
      "corpus_version" => "facet-confidence-corpus-v1", "status" => "completed", "cost_cents" => 3)
    expect(events.map { |event| event.fetch("input_revision") }).to eq([ 2, 3, 4, 3, 2, 2, 2, 2 ])
    expect(metrics).to include(coverage: { assessed: 8, total: 8 })
    expect(metrics.fetch(:false_readiness).fetch(:count)).to eq(6)
    expect(metrics.fetch(:assessment_cost_cents)).to eq(24)
  end

  it "refuses to attribute a run the provider served from another model" do
    stub_assessment(model: "other-model")

    result = described_class.call(project: project, corpus_path: corpus_path.to_s, ledger_path: ledger_path.to_s)

    expect(result.recorded).to be_empty
    expect(result.refused.length).to eq(8)
    expect(result.refused.first.fetch(:error)).to include("provider served model other-model")
    expect(File.exist?(ledger_path)).to be false
  end

  it "records a failed run as an operational failure without inventing scores" do
    allow(AgentHarness).to receive(:send_message).and_return(
      double(success?: false, output: "", model: "claude-sonnet-4-6", metadata: {})
    )

    described_class.call(project: project, corpus_path: corpus_path.to_s, ledger_path: ledger_path.to_s)

    event = ledger_events.first
    expect(event).to include("status" => "failed", "intent_score" => nil, "technical_score" => nil)
    expect(metrics.fetch(:operational_failures).fetch(:count)).to eq(8)
    expect(metrics.fetch(:false_readiness).fetch(:count)).to eq(0)
  end

  it "keeps one unexpected case failure from aborting the corpus" do
    allow(AgentHarness).to receive(:send_message).and_raise(RuntimeError, "provider exploded")

    result = described_class.call(project: project, corpus_path: corpus_path.to_s, ledger_path: ledger_path.to_s)

    expect(result.recorded.length).to eq(8)
    expect(result.refused).to be_empty
    expect(ledger_events.map { |event| event.fetch("status") }.uniq).to eq([ "failed" ])
    expect(metrics.fetch(:operational_failures).fetch(:count)).to eq(8)
  end

  it "refuses to replay identical case input" do
    stub_assessment

    described_class.call(project: project, corpus_path: corpus_path.to_s, ledger_path: ledger_path.to_s)
    replay = described_class.call(project: project, corpus_path: corpus_path.to_s, ledger_path: ledger_path.to_s)

    expect(replay.recorded).to be_empty
    expect(replay.refused.length).to eq(8)
    expect(replay.refused.first.fetch(:error)).to include("identical input cannot be replayed")
  end

  it "keeps an operational failure from blocking the measured run of the same case" do
    allow(AgentHarness).to receive(:send_message).and_return(
      double(success?: false, output: "", model: "claude-sonnet-4-6", metadata: {})
    )
    described_class.call(project: project, corpus_path: corpus_path.to_s, ledger_path: ledger_path.to_s)

    stub_assessment
    measured = described_class.call(project: project, corpus_path: corpus_path.to_s, ledger_path: ledger_path.to_s)

    expect(measured.recorded.length).to eq(8)
    expect(measured.refused).to be_empty
    expect(metrics.fetch(:operational_failures).fetch(:count)).to eq(8)
    expect(metrics.fetch(:coverage)).to eq(assessed: 8, total: 8)
  end

  it "keeps the synthetic corpus records out of the tenant" do
    stub_assessment

    described_class.call(project: project, corpus_path: corpus_path.to_s, ledger_path: ledger_path.to_s)

    expect(FeatureIntentFacet.where(name: corpus_case("FC-CORPUS-01").dig("facet", "name"))).to be_empty
    expect(FeatureIntentFacetEvidence.where(source_reference: "sync-sketch-statement")).to be_empty
  end
end
