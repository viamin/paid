# frozen_string_literal: true

require "rails_helper"
require "json"
require "tmpdir"

require Rails.root.join("lib/facet_confidence/assessment_corpus_ledger")
require Rails.root.join("lib/facet_confidence/assessment_outcome_report")

# @spec FACET-CONFIDENCE-018
RSpec.describe FacetConfidence::AssessmentOutcomeReport do
  let(:corpus_dir) { Pathname.new(Dir.mktmpdir) }
  let(:corpus) { corpus_dir.join("corpus.yml") }
  let(:ledger) { corpus_dir.join("ledger.jsonl") }
  let(:project) { create(:project, intent_threshold: 80, technical_threshold: 80) }

  after { corpus_dir.rmtree if corpus_dir.exist? }

  before do
    File.write(corpus, { "corpus_version" => "facet-confidence-corpus-v1", "frozen_at" => "2026-10-23T00:00:00Z",
      "rubric" => { "version" => "facet-confidence-v1", "model" => "claude-sonnet-4-6" },
      "threshold_defaults" => { "intent" => 80, "technical" => 80 },
      "cases" => [ not_ready_case, decisive_case, ready_case, boundary_case, *filler_cases ] }.to_yaml)
  end

  describe ".metrics for a complete measured ledger" do
    before do
      write_events!(
        run_event("FC-CORPUS-01", status: "completed", intent_score: 85, technical_score: 82), # expected not ready -> false readiness
        run_event("FC-CORPUS-02", status: "unknown", technical_score: 90),                     # expected completed -> unnecessary clarification
        run_event("FC-CORPUS-03", status: "completed", intent_score: 82, technical_score: 84), # expected ready -> correct readiness
        run_event("FC-CORPUS-04", status: "completed", intent_score: 79, technical_score: 80),
        correction_event("FC-CORPUS-03", input_revision: 3),
        rework_event("FC-CORPUS-01", run_event_id: "run-FC-CORPUS-01", cost_cents: 400))
    end

    it "reports false readiness against the expected not-ready band" do
      metrics = described_class.metrics(corpus_path: corpus, ledger_path: ledger)

      expect(metrics[:false_readiness][:count]).to eq(1)
      expect(metrics[:false_readiness][:cases]).to eq(%w[FC-CORPUS-01])
      expect(metrics[:false_readiness][:rate]).to eq("50.0% (1 / 2)")
    end

    it "reports unnecessary clarification against the decisive expectation" do
      metrics = described_class.metrics(corpus_path: corpus, ledger_path: ledger)

      expect(metrics[:unnecessary_clarification][:count]).to eq(1)
      expect(metrics[:unnecessary_clarification][:cases]).to eq(%w[FC-CORPUS-02])
    end

    it "reports human corrections, assessment cost, and downstream rework" do
      metrics = described_class.metrics(corpus_path: corpus, ledger_path: ledger)

      expect(metrics[:human_corrections][:count]).to eq(1)
      expect(metrics[:human_corrections][:cases]).to eq(%w[FC-CORPUS-03])
      expect(metrics[:assessment_cost_cents]).to eq(400)
      expect(metrics[:downstream_rework][:events]).to eq(1)
      expect(metrics[:downstream_rework][:cost_cents]).to eq(400)
      expect(metrics[:downstream_rework][:cases]).to eq(%w[FC-CORPUS-01])
    end

    it "reports corpus coverage" do
      metrics = described_class.metrics(corpus_path: corpus, ledger_path: ledger)

      expect(metrics[:coverage][:assessed]).to eq(4)
      expect(metrics[:coverage][:total]).to eq(8)
    end
  end

  describe ".metrics" do
    it "uses the latest run per case when input revisions advance" do
      write_events!(
        run_event("FC-CORPUS-01", status: "completed", intent_score: 85, technical_score: 82),
        correction_event("FC-CORPUS-01", input_revision: 3),
        run_event("FC-CORPUS-01", event_id: "run-FC-CORPUS-01-r2", input_revision: 3, status: "completed", intent_score: 40, technical_score: 45,
          evidence_references: run_references + [ "correction-FC-CORPUS-01" ]))

      metrics = described_class.metrics(corpus_path: corpus, ledger_path: ledger)

      expect(metrics[:false_readiness][:count]).to eq(0)
    end

    it "retains a failed run in operational failure metrics after a successful re-run" do
      corpus_cases = [ not_ready_case, decisive_case, ready_case, boundary_case, *filler_cases ]
      write_events!(*corpus_cases.map { |corpus_case| run_event(corpus_case.fetch("id"), status: "failed") })
      write_events!(
        correction_event("FC-CORPUS-01", input_revision: 3),
        run_event("FC-CORPUS-01", event_id: "run-FC-CORPUS-01-r2", input_revision: 3,
          status: "completed", intent_score: 40, technical_score: 45,
          evidence_references: run_references + [ "correction-FC-CORPUS-01" ]))

      metrics = described_class.metrics(corpus_path: corpus, ledger_path: ledger)

      expect(metrics[:operational_failures]).to include(
        count: 8, rate: "88.9% (8 / 9)", cases: corpus_cases.map { |corpus_case| corpus_case.fetch("id") })
    end

    it "keeps a failed run out of unnecessary clarification and reports it as an operational failure" do
      write_events!(
        run_event("FC-CORPUS-02", status: "failed"),                # expected completed -> provider/runtime failure
        run_event("FC-CORPUS-03", status: "clarification_needed"))  # expected completed -> unnecessary clarification

      metrics = described_class.metrics(corpus_path: corpus, ledger_path: ledger)

      expect(metrics[:unnecessary_clarification][:count]).to eq(1)
      expect(metrics[:unnecessary_clarification][:cases]).to eq(%w[FC-CORPUS-03])
      expect(metrics[:unnecessary_clarification][:rate]).to eq("100.0% (1 / 1)")
      expect(metrics[:operational_failures][:count]).to eq(1)
      expect(metrics[:operational_failures][:cases]).to eq(%w[FC-CORPUS-02])
      expect(metrics[:operational_failures][:rate]).to eq("50.0% (1 / 2)")
    end

    it "keeps a failed run out of the false-readiness and band-divergence measures" do
      write_events!(run_event("FC-CORPUS-01", status: "failed"))

      metrics = described_class.metrics(corpus_path: corpus, ledger_path: ledger)

      expect(metrics[:false_readiness][:count]).to eq(0)
      expect(metrics[:false_readiness][:rate]).to eq("not established")
      expect(metrics[:band_divergences][:count]).to eq(0)
      expect(metrics[:operational_failures][:count]).to eq(1)
    end

    it "counts band divergences so quality can be evaluated before any tuning" do
      write_events!(run_event("FC-CORPUS-01", status: "completed", intent_score: 85, technical_score: 82))

      metrics = described_class.metrics(corpus_path: corpus, ledger_path: ledger)

      expect(metrics[:band_divergences][:count]).to eq(1)
      expect(metrics[:band_divergences][:cases]).to eq(%w[FC-CORPUS-01])
    end

    it "blocks threshold or rubric tuning proposals while corpus coverage is incomplete" do
      write_events!(run_event("FC-CORPUS-01", status: "unknown"))

      metrics = described_class.metrics(corpus_path: corpus, ledger_path: ledger)

      expect(metrics[:tuning_gate]).to eq("blocked_incomplete_coverage")
    end

    it "does not count failed runs as quality coverage for threshold or rubric tuning" do
      write_events!(*[ not_ready_case, decisive_case, ready_case, boundary_case, *filler_cases ].map do |corpus_case|
        run_event(corpus_case.fetch("id"), status: "failed")
      end)

      metrics = described_class.metrics(corpus_path: corpus, ledger_path: ledger)

      expect(metrics[:coverage]).to eq(assessed: 0, total: 8)
      expect(metrics[:operational_failures][:count]).to eq(8)
      expect(metrics[:tuning_gate]).to eq("blocked_incomplete_coverage")
    end

    it "requires tuning proposals to cite the recorded metrics once coverage is complete" do
      write_events!(
        run_event("FC-CORPUS-01", status: "completed", intent_score: 40, technical_score: 45),
        run_event("FC-CORPUS-02", status: "completed", intent_score: 85, technical_score: 84),
        run_event("FC-CORPUS-03", status: "completed", intent_score: 82, technical_score: 84),
        run_event("FC-CORPUS-04", status: "completed", intent_score: 79, technical_score: 80),
        *expected_band_runs)

      metrics = described_class.metrics(corpus_path: corpus, ledger_path: ledger)

      expect(metrics[:tuning_gate]).to eq("metrics_required")
    end
  end

  describe ".compile" do
    it "refuses to compile outcome measures before every corpus case has a run" do
      write_events!(run_event("FC-CORPUS-01", status: "unknown"))

      expect { described_class.compile(corpus_path: corpus, ledger_path: ledger) }
        .to raise_error(FacetConfidence::AssessmentCorpusLedger::PendingOperatorInput, /every corpus case needs a non-failed assessment verdict/)
    end

    it "compiles the repository-visible outcome worksheet with every required measure" do
      write_events!(
        run_event("FC-CORPUS-01", status: "completed", intent_score: 85, technical_score: 82),
        run_event("FC-CORPUS-02", status: "completed", intent_score: 85, technical_score: 84),
        run_event("FC-CORPUS-03", status: "completed", intent_score: 82, technical_score: 84),
        run_event("FC-CORPUS-04", status: "completed", intent_score: 79, technical_score: 80),
        *expected_band_runs,
        correction_event("FC-CORPUS-03", input_revision: 3),
        rework_event("FC-CORPUS-01", run_event_id: "run-FC-CORPUS-01", cost_cents: 400))

      worksheet = described_class.compile(corpus_path: corpus, ledger_path: ledger)

      expect(worksheet).to include("| False readiness | 1")
      expect(worksheet).to include("| Unnecessary clarification | 0")
      expect(worksheet).to include("| Human corrections | 1")
      expect(worksheet).to include("| Assessment cost | 800 cents |")
      expect(worksheet).to include("| Downstream rework | 1 events / 400 cents |")
      expect(worksheet).to include("| Operational failures | 0")
      expect(worksheet).to include("Threshold or rubric tuning proposals must cite the outcome metrics above")
    end
  end

  describe "readiness parity with ScopedReadiness", :db do
    it "agrees with the deterministic verdict at the 79/80 boundary and at 80/80" do
      expect(FeatureIntents::ScopedReadiness.call(project:, mapping: mapping_for(intent: 79, technical: 80))).not_to be_ready
      expect(FeatureIntents::ScopedReadiness.call(project:, mapping: mapping_for(intent: 80, technical: 80))).to be_ready

      write_events!(run_event("FC-CORPUS-04", event_id: "run-boundary-79", status: "completed", intent_score: 79, technical_score: 80))
      expect(described_class.metrics(corpus_path: corpus, ledger_path: ledger)[:false_readiness][:count]).to eq(0)

      write_events!(correction_event("FC-CORPUS-04", input_revision: 3),
        run_event("FC-CORPUS-04", event_id: "run-boundary-80", input_revision: 3, status: "completed", intent_score: 80, technical_score: 80,
          evidence_references: run_references + [ "correction-FC-CORPUS-04" ]))
      expect(described_class.metrics(corpus_path: corpus, ledger_path: ledger)[:false_readiness][:count]).to eq(1)
    end
  end

  def mapping_for(intent:, technical:)
    { "coverage" => "complete", "scope_revision" => "issue-scope-1",
      "prerequisites" => [ { "id" => "export", "assessment" =>
        { "status" => "completed", "evidence_revision" => 2, "intent_score" => intent, "technical_score" => technical } } ] }
  end

  def write_events!(*events)
    events.each { |event| FacetConfidence::AssessmentCorpusLedger.append!(ledger_path: ledger, event: event, corpus_path: corpus) }
  end

  def run_event(case_id, status:, **attributes)
    { "event_id" => attributes.fetch(:event_id, "run-#{case_id}"), "recorded_at" => "2026-10-23T09:00:00Z", "type" => "assessment_run", "case_id" => case_id,
      "corpus_version" => "facet-confidence-corpus-v1", "rubric_version" => "facet-confidence-v1",
      "model_version" => "claude-sonnet-4-6", "input_revision" => attributes.fetch(:input_revision, 2), "status" => status,
      "intent_score" => attributes[:intent_score], "technical_score" => attributes[:technical_score],
      "evidence_references" => attributes.fetch(:evidence_references, run_references), "cost_cents" => 100 }
  end

  def correction_event(case_id, input_revision:)
    { "event_id" => "correction-#{case_id}", "recorded_at" => "2026-10-23T10:00:00Z", "type" => "correction",
      "case_id" => case_id, "input_revision" => input_revision, "statement" => "Correction recorded after the run." }
  end

  def rework_event(case_id, run_event_id:, cost_cents:)
    { "event_id" => "rework-#{case_id}", "recorded_at" => "2026-10-23T11:00:00Z", "type" => "rework",
      "case_id" => case_id, "run_event_id" => run_event_id, "cost_cents" => cost_cents,
      "description" => "Downstream rework caused by the run outcome." }
  end

  def run_references
    %w[chat-message-1 repository-fact-1]
  end

  def base_case(id, shape, expected)
    { "id" => id, "shape" => shape, "selection_rationale" => "Representative #{shape.tr('_', ' ')} scenario.",
      "facet" => { "name" => "Facet #{id}", "design_claim" => "Claim #{id}" },
      "direction" => { "name" => "Direction #{id}", "description" => "Description #{id}" },
      "evidence" => [
        { "reference" => "chat-message-1", "source_type" => "human_statement", "actor_role" => "owner",
          "statement" => "Statement #{id}.", "occurred_at" => "2026-10-20T09:00:00Z" },
        { "reference" => "repository-fact-1", "source_type" => "repository_fact", "actor_role" => "agent",
          "statement" => "Fact #{id}.", "occurred_at" => "2026-10-20T10:00:00Z" }
      ],
      "thresholds" => { "intent" => 80, "technical" => 80 },
      "expected" => expected }
  end

  def not_ready_case
    base_case("FC-CORPUS-01", "provisional_direction",
      "status" => "completed", "intent_band" => "below_threshold", "technical_band" => "below_threshold",
      "readiness" => "not_ready", "rationale" => "Provisional direction is not explicit intent.")
  end

  def decisive_case
    base_case("FC-CORPUS-02", "explicit_correction",
      "status" => "completed", "intent_band" => "at_or_above_threshold", "technical_band" => "at_or_above_threshold",
      "readiness" => "ready", "rationale" => "The correction is explicit and technically supported.")
  end

  def ready_case
    base_case("FC-CORPUS-03", "research_scope",
      "status" => "completed", "intent_band" => "at_or_above_threshold", "technical_band" => "at_or_above_threshold",
      "readiness" => "ready", "rationale" => "The investigation scope is clear and feasible.")
  end

  def boundary_case
    base_case("FC-CORPUS-04", "boundary_79_80",
      "status" => "completed", "intent_band" => "below_threshold", "technical_band" => "at_or_above_threshold",
      "readiness" => "not_ready", "rationale" => "Intent 79 fails the 80 threshold while technical 80 meets it.")
  end

  def filler_cases
    [
      base_case("FC-CORPUS-05", "repeated_agent_suggestions",
        "status" => "unknown", "intent_band" => "unknown", "technical_band" => "at_or_above_threshold",
        "readiness" => "not_ready", "rationale" => "Agent repetition is not human agreement."),
      base_case("FC-CORPUS-06", "collaborator_disagreement",
        "status" => "clarification_needed", "intent_band" => "unknown", "technical_band" => "at_or_above_threshold",
        "readiness" => "not_ready", "rationale" => "Disagreement triggers clarification."),
      base_case("FC-CORPUS-07", "unknown_intent_strong_technical",
        "status" => "unknown", "intent_band" => "unknown", "technical_band" => "at_or_above_threshold",
        "readiness" => "not_ready", "rationale" => "A prototype does not establish intent."),
      base_case("FC-CORPUS-08", "strong_intent_weak_feasibility",
        "status" => "completed", "intent_band" => "at_or_above_threshold", "technical_band" => "below_threshold",
        "readiness" => "not_ready", "rationale" => "Insistence does not establish feasibility.")
    ]
  end

  def expected_band_runs
    filler_cases.map do |corpus_case|
      expected = corpus_case.fetch("expected")
      completed = expected.fetch("status") == "completed"
      run_event(corpus_case.fetch("id"), status: expected.fetch("status"),
        intent_score: completed ? band_score(expected.fetch("intent_band")) : nil,
        technical_score: band_score(expected.fetch("technical_band")))
    end
  end

  def band_score(band)
    { "unknown" => nil, "below_threshold" => 79, "at_or_above_threshold" => 80 }.fetch(band)
  end
end
