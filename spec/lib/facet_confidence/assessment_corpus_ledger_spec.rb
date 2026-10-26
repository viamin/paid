# frozen_string_literal: true

require "rails_helper"
require "json"
require "tmpdir"

require Rails.root.join("lib/facet_confidence/assessment_corpus_ledger")

# @spec FACET-CONFIDENCE-016 @spec FACET-CONFIDENCE-017
RSpec.describe FacetConfidence::AssessmentCorpusLedger, :no_db do
  let(:committed_corpus) { Rails.root.join("docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml") }
  let(:corpus) { Pathname.new(Dir.mktmpdir).join("corpus.yml") }
  let(:ledger) { Pathname.new(Dir.mktmpdir).join("ledger.jsonl") }

  after do
    corpus.dirname.rmtree if corpus.dirname.exist?
    ledger.dirname.rmtree if ledger.dirname.exist?
  end

  before do
    File.write(corpus, minimal_document(corpus_cases(*described_class::REQUIRED_SHAPES)))
  end

  describe "the committed repository corpus" do
    it "covers every required representative shape with pinned rubric and model identity" do
      cases = described_class.load_corpus(committed_corpus)

      expect(cases.map { |corpus_case| corpus_case.fetch("shape") }.uniq).to match_array(described_class::REQUIRED_SHAPES)
      document = YAML.safe_load_file(committed_corpus)
      expect(document.fetch("rubric").fetch("version")).to eq(FeatureIntents::AssessFacet::RUBRIC_VERSION)
      expect(document.fetch("rubric").fetch("model")).to eq(FeatureIntents::AssessFacet::MODEL_VERSION)
      expect(document.fetch("threshold_defaults")).to eq("intent" => 80, "technical" => 80)
    end

    it "records input revisions, thresholds, expected bands, and correction precedence per case" do
      cases = described_class.load_corpus(committed_corpus)

      cases.each do |corpus_case|
        expect(corpus_case.fetch("evidence_revision")).to eq(corpus_case.fetch("evidence").length)
        expect(corpus_case.dig("expected", "readiness")).to be_in(%w[ready not_ready])
        expect(corpus_case.fetch("selection_rationale")).to be_present
      end
      corrections = cases.select { |corpus_case| corpus_case["shape"] == "explicit_correction" }.flat_map { |corpus_case| corpus_case["expected"]["must_cite"] }
      expect(corrections).to be_present
    end
  end

  describe ".load_corpus" do
    it "rejects a corpus that misses a required representative shape" do
      File.write(corpus, minimal_document(corpus_cases("provisional_direction")))

      expect { described_class.load_corpus(corpus) }
        .to raise_error(described_class::InvalidLedger, /must cover every required shape/)
    end

    it "rejects missing default thresholds" do
      document = YAML.safe_load_file(corpus)
      document.delete("threshold_defaults")
      File.write(corpus, document.to_yaml)

      expect { described_class.load_corpus(corpus) }
        .to raise_error(described_class::InvalidLedger, /threshold_defaults with bounded integer intent and technical thresholds is required/)
    end

    it "rejects malformed default thresholds" do
      document = YAML.safe_load_file(corpus)
      document["threshold_defaults"] = { "intent" => "80", "technical" => 80 }
      File.write(corpus, document.to_yaml)

      expect { described_class.load_corpus(corpus) }
        .to raise_error(described_class::InvalidLedger, /threshold_defaults with bounded integer intent and technical thresholds is required/)
    end

    it "defaults omitted case thresholds" do
      document = YAML.safe_load_file(corpus)
      document.fetch("cases").first.delete("thresholds")
      File.write(corpus, document.to_yaml)

      expect(described_class.load_corpus(corpus).first.fetch("thresholds"))
        .to eq("intent" => 80, "technical" => 80)
    end

    it "rejects malformed case threshold overrides" do
      document = YAML.safe_load_file(corpus)
      document.fetch("cases").second["thresholds"] = { "intent" => 80 }
      File.write(corpus, document.to_yaml)

      expect { described_class.load_corpus(corpus) }
        .to raise_error(described_class::InvalidLedger, /thresholds must provide bounded integer intent and technical values/)
    end

    it "rejects duplicate case ids" do
      cases = corpus_cases(*described_class::REQUIRED_SHAPES) + [ corpus_case("FC-CORPUS-01", "provisional_direction") ]
      File.write(corpus, minimal_document(cases))

      expect { described_class.load_corpus(corpus) }
        .to raise_error(described_class::InvalidLedger, /case ids must be unique/)
    end

    it "rejects a case with a non-mapping facet or direction" do
      document = YAML.safe_load_file(corpus)
      document.fetch("cases").first["facet"] = "not a mapping"
      File.write(corpus, document.to_yaml)

      expect { described_class.load_corpus(corpus) }
        .to raise_error(described_class::InvalidLedger, /facet and direction must be mappings/)
    end

    it "rejects evidence that supersedes an unknown reference" do
      cases = corpus_cases(*(described_class::REQUIRED_SHAPES - %w[explicit_correction]))
      broken = corpus_case("FC-CORPUS-02", "explicit_correction")
      broken["evidence"].last["supersedes"] = "missing-reference"
      File.write(corpus, minimal_document(cases + [ broken ]))

      expect { described_class.load_corpus(corpus) }
        .to raise_error(described_class::InvalidLedger, /supersedes an unknown reference/)
    end

    it "rejects a case whose expected readiness contradicts its expected bands" do
      cases = corpus_cases(*(described_class::REQUIRED_SHAPES - %w[provisional_direction]))
      broken = corpus_case("FC-CORPUS-01", "provisional_direction")
      broken["expected"]["readiness"] = "ready"
      File.write(corpus, minimal_document(cases + [ broken ]))

      expect { described_class.load_corpus(corpus) }
        .to raise_error(described_class::InvalidLedger, /expected readiness contradicts/)
    end

    it "rejects a non-completed expectation that still claims a known intent band" do
      cases = corpus_cases(*(described_class::REQUIRED_SHAPES - %w[collaborator_disagreement]))
      broken = corpus_case("FC-CORPUS-04", "collaborator_disagreement")
      broken["expected"]["intent_band"] = "at_or_above_threshold"
      File.write(corpus, minimal_document(cases + [ broken ]))

      expect { described_class.load_corpus(corpus) }
        .to raise_error(described_class::InvalidLedger, /unknown status cannot claim a known intent band/)
    end
  end

  describe ".validate!" do
    it "accepts a complete ledger that records corpus, rubric, model, and input revisions for every run" do
      write_ledger!(complete_events)

      expect(described_class.validate!(corpus_path: corpus, ledger_path: ledger)).to be(true)
    end

    it "rejects a run that omits the rubric or model version" do
      events = complete_events
      events[0].delete("rubric_version")
      write_ledger!(events)

      expect { described_class.validate!(corpus_path: corpus, ledger_path: ledger) }
        .to raise_error(described_class::InvalidLedger, /must record the rubric version/)
    end

    it "rejects a run recorded against a different corpus revision" do
      events = complete_events
      events[0]["corpus_digest"] = "f" * 64
      write_ledger!(events)

      expect { described_class.validate!(corpus_path: corpus, ledger_path: ledger) }
        .to raise_error(described_class::InvalidLedger, /frozen corpus content/)
    end

    it "rejects a replay of identical case input at the same input revision" do
      events = complete_events
      replay = events[0].merge("event_id" => "replay-1")
      write_ledger!(events + [ replay ])

      expect { described_class.validate!(corpus_path: corpus, ledger_path: ledger) }
        .to raise_error(described_class::InvalidLedger, /identical input cannot be replayed/)
    end

    it "accepts a verdict run after an operational failure at the same input revision" do
      events = complete_events
      failure = events.first.merge("event_id" => "failed-1", "status" => "failed", "intent_score" => nil,
        "technical_score" => nil, "evidence_references" => [], "recorded_at" => "2026-10-23T08:00:00Z")
      write_ledger!([ failure ] + events)

      expect(described_class.validate!(corpus_path: corpus, ledger_path: ledger)).to be(true)
    end

    it "rejects a run whose input revision rewinds behind an earlier run" do
      events = complete_events
      events << events[0].merge("event_id" => "rewind-1", "input_revision" => 1, "recorded_at" => later_timestamp)
      write_ledger!(events)

      expect { described_class.validate!(corpus_path: corpus, ledger_path: ledger) }
        .to raise_error(described_class::InvalidLedger, /input revisions must advance/)
    end

    it "rejects a first run that does not assess the frozen case input revision" do
      events = complete_events
      events[0]["input_revision"] = 9
      write_ledger!(events)

      expect { described_class.validate!(corpus_path: corpus, ledger_path: ledger) }
        .to raise_error(described_class::InvalidLedger, /first assessment run must assess the frozen case input revision/)
    end

    it "rejects a re-run without a recorded correction at the new input revision" do
      events = complete_events
      events << events[0].merge("event_id" => "rerun-1", "input_revision" => 4, "recorded_at" => later_timestamp)
      write_ledger!(events)

      expect { described_class.validate!(corpus_path: corpus, ledger_path: ledger) }
        .to raise_error(described_class::InvalidLedger, /re-run requires a recorded correction/)
    end

    it "requires a re-run to cite the correction event at its input revision" do
      events = complete_events
      events << correction_event(case_id: "FC-CORPUS-01", input_revision: 3)
      events << events[0].merge("event_id" => "rerun-1", "input_revision" => 3, "recorded_at" => later_timestamp)
      write_ledger!(events)

      expect { described_class.validate!(corpus_path: corpus, ledger_path: ledger) }
        .to raise_error(described_class::InvalidLedger, /must cite the correction evidence: correction-1/)
    end

    it "accepts a re-run that cites the correction event at its input revision" do
      events = complete_events
      events << correction_event(case_id: "FC-CORPUS-01", input_revision: 3)
      events << events[0].merge(
        "event_id" => "rerun-1",
        "input_revision" => 3,
        "recorded_at" => later_timestamp,
        "evidence_references" => [ "correction-1" ]
      )
      write_ledger!(events)

      expect(described_class.validate!(corpus_path: corpus, ledger_path: ledger)).to be(true)
    end

    it "rejects a completed run that cites superseded evidence instead of the correction" do
      events = complete_events
      correction_run = events.find { |event| event["case_id"] == "FC-CORPUS-02" }
      correction_run["evidence_references"] = [ "early-hover-statement" ]
      write_ledger!(events)

      expect { described_class.validate!(corpus_path: corpus, ledger_path: ledger) }
        .to raise_error(described_class::InvalidLedger, /must cite the correction evidence/)
    end

    it "rejects a correction that rewinds behind the recorded input revision" do
      events = complete_events
      events << { "event_id" => "correction-rewind", "recorded_at" => later_timestamp, "type" => "correction",
        "case_id" => "FC-CORPUS-01", "input_revision" => 1, "statement" => "Actually, sync should stay manual.",
        "corpus_version" => corpus_version, "corpus_digest" => described_class.corpus_digest(corpus) }
      write_ledger!(events)

      expect { described_class.validate!(corpus_path: corpus, ledger_path: ledger) }
        .to raise_error(described_class::InvalidLedger, /advance beyond the recorded input revision/)
    end

    it "rejects a correction recorded before any assessment run of the case" do
      events = complete_events.reject { |event| event["case_id"] == "FC-CORPUS-02" }
      events << { "event_id" => "correction-without-run", "recorded_at" => later_timestamp, "type" => "correction",
        "case_id" => "FC-CORPUS-02", "input_revision" => 4, "statement" => "Correction before any run.",
        "corpus_version" => corpus_version, "corpus_digest" => described_class.corpus_digest(corpus) }
      write_ledger!(events)

      expect { described_class.validate!(corpus_path: corpus, ledger_path: ledger) }
        .to raise_error(described_class::InvalidLedger, /correction must follow an assessment run/)
    end

    it "accepts a correction recorded after a run at an advanced input revision" do
      events = complete_events
      events << correction_event(case_id: "FC-CORPUS-01", input_revision: 3)
      write_ledger!(events)

      expect(described_class.validate!(corpus_path: corpus, ledger_path: ledger)).to be(true)
    end

    it "rejects a correction that supersedes evidence outside its case" do
      events = complete_events
      events << { "event_id" => "correction-unknown-reference", "recorded_at" => later_timestamp, "type" => "correction",
        "case_id" => "FC-CORPUS-01", "input_revision" => 3, "statement" => "Sync should stay manual for now.",
        "supersedes_reference" => "unknown-reference", "corpus_version" => corpus_version,
        "corpus_digest" => described_class.corpus_digest(corpus) }
      write_ledger!(events)

      expect { described_class.validate!(corpus_path: corpus, ledger_path: ledger) }
        .to raise_error(described_class::InvalidLedger, /correction supersedes_reference must reference evidence of the case/)
    end

    it "rejects rework that references a run outside its case" do
      events = complete_events
      events << { "event_id" => "rework-1", "recorded_at" => later_timestamp, "type" => "rework",
        "case_id" => "FC-CORPUS-01", "run_event_id" => events[1].fetch("event_id"), "cost_cents" => 500,
        "description" => "Rework after premature release.", "corpus_version" => corpus_version,
        "corpus_digest" => described_class.corpus_digest(corpus) }
      write_ledger!(events)

      expect { described_class.validate!(corpus_path: corpus, ledger_path: ledger) }
        .to raise_error(described_class::InvalidLedger, /rework must reference an assessment run of the same case/)
    end
  end

  describe ".append!" do
    it "rejects an invalid prospective event without writing it to the append-only ledger" do
      event = { "event_id" => "event-1", "recorded_at" => "2026-10-23T09:00:00Z", "type" => "assessment_run" }

      expect do
        described_class.append!(ledger_path: ledger, event: event, corpus_path: corpus)
      end.to raise_error(described_class::InvalidLedger, /event references a case outside the frozen corpus/)

      expect(ledger).not_to exist
    end

    it "stamps the event with the frozen corpus identity and rejects duplicate event ids" do
      event = complete_events.first.merge("event_id" => "event-1")
      described_class.append!(ledger_path: ledger, event: event, corpus_path: corpus)

      expect(JSON.parse(File.read(ledger))).to include("corpus_version" => corpus_version, "corpus_digest" => described_class.corpus_digest(corpus))
      expect do
        described_class.append!(ledger_path: ledger, event: event, corpus_path: corpus)
      end.to raise_error(described_class::InvalidLedger, /event_id already exists/)
    end

    it "serializes overlapping appends so only one duplicate event is accepted" do
      event = complete_events.first.merge("event_id" => "event-1")
      results = Queue.new
      start = Queue.new
      threads = 2.times.map do
        Thread.new do
          start.pop
          described_class.append!(ledger_path: ledger, event: event, corpus_path: corpus)
          results << :appended
        rescue described_class::InvalidLedger => error
          results << error.message
        end
      end

      2.times { start << true }
      threads.each(&:join)

      expect(results.size).to eq(2)
      expect(2.times.map { results.pop }).to contain_exactly(:appended, "event_id already exists")
      expect(described_class.events(ledger).map { |entry| entry.fetch("event_id") }).to eq([ "event-1" ])
    end
  end

  def corpus_version
    "facet-confidence-corpus-v1"
  end

  def later_timestamp = "2026-10-23T12:00:00Z"

  def write_ledger!(events)
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))
  end

  def correction_event(case_id:, input_revision:)
    { "event_id" => "correction-1", "recorded_at" => later_timestamp, "type" => "correction",
      "case_id" => case_id, "input_revision" => input_revision, "statement" => "Sync should stay manual for now.",
      "supersedes_reference" => "sync-sketch-statement", "corpus_version" => corpus_version,
      "corpus_digest" => described_class.corpus_digest(corpus) }
  end

  def complete_events
    loadable_cases.map do |corpus_case|
      run_event_for(corpus_case).merge("corpus_digest" => described_class.corpus_digest(corpus))
    end
  end

  def run_event_for(corpus_case)
    expected = corpus_case.fetch("expected")
    status = expected.fetch("status")
    completed = status == "completed"
    intent = completed ? band_score(expected.fetch("intent_band"), corpus_case.fetch("thresholds").fetch("intent")) : nil
    technical = completed || expected.fetch("technical_band") != "unknown" ? band_score(expected.fetch("technical_band"), corpus_case.fetch("thresholds").fetch("technical")) : nil
    references = corpus_case.fetch("evidence").map { |evidence| evidence.fetch("reference") } - Array(expected["must_not_cite"])
    references = Array(expected["must_cite"]) if expected["must_cite"].present?

    { "event_id" => "run-#{corpus_case.fetch('id')}", "recorded_at" => "2026-10-23T09:00:00Z", "type" => "assessment_run",
      "case_id" => corpus_case.fetch("id"), "corpus_version" => corpus_version,
      "rubric_version" => "facet-confidence-v1", "model_version" => "claude-sonnet-4-6",
      "input_revision" => corpus_case.fetch("evidence_revision"), "status" => status,
      "intent_score" => intent, "technical_score" => technical,
      "evidence_references" => references.uniq, "cost_cents" => 100 }
  end

  def band_score(band, threshold)
    { "unknown" => nil, "below_threshold" => threshold - 1, "at_or_above_threshold" => threshold }.fetch(band)
  end

  def loadable_cases
    described_class.load_corpus(corpus)
  end

  def minimal_document(cases)
    { "corpus_version" => corpus_version, "frozen_at" => "2026-10-23T00:00:00Z",
      "rubric" => { "version" => "facet-confidence-v1", "model" => "claude-sonnet-4-6" },
      "threshold_defaults" => { "intent" => 80, "technical" => 80 }, "cases" => cases }.to_yaml
  end

  def corpus_cases(*shapes)
    shapes.map { |shape| corpus_case(corpus_case_id(shape), shape) }
  end

  def corpus_case_id(shape)
    "FC-CORPUS-#{format('%02d', described_class::REQUIRED_SHAPES.index(shape) + 1)}"
  end

  def corpus_case(id, shape)
    case shape
    when "provisional_direction" then provisional_direction_case(id)
    when "explicit_correction" then explicit_correction_case(id)
    when "repeated_agent_suggestions" then repeated_agent_suggestions_case(id)
    when "collaborator_disagreement" then collaborator_disagreement_case(id)
    when "unknown_intent_strong_technical" then unknown_intent_case(id)
    when "strong_intent_weak_feasibility" then weak_feasibility_case(id)
    when "research_scope" then research_scope_case(id)
    when "boundary_79_80" then boundary_case(id)
    else raise "unknown shape #{shape}"
    end
  end

  def base_case(id, shape, facet_name, design_claim, direction_name, direction_description)
    { "id" => id, "shape" => shape, "selection_rationale" => "Representative #{shape.tr('_', ' ')} scenario.",
      "facet" => { "name" => facet_name, "design_claim" => design_claim },
      "direction" => { "name" => direction_name, "description" => direction_description },
      "evidence" => [], "thresholds" => { "intent" => 80, "technical" => 80 },
      "expected" => {} }
  end

  def evidence(reference, source_type, actor_role, statement, occurred_at, supersedes: nil)
    { "reference" => reference, "source_type" => source_type, "actor_role" => actor_role,
      "statement" => statement, "occurred_at" => occurred_at, "supersedes" => supersedes }.compact
  end

  def provisional_direction_case(id)
    base_case(id, "provisional_direction", "Cross-device draft sync", "Unfinished answers stay preserved while cross-device behavior is explored.",
      "automatic draft sync", "Sync drafts across devices without an explicit share action.").merge(
        "evidence" => [
          evidence("sync-sketch-statement", "human_statement", "owner", "I started sketching the sync flow on my phone; not sure yet whether it should just work.", "2026-10-20T09:00:00Z"),
          evidence("sync-spike-note", "repository_fact", "agent", "Sandbox spike syncs drafts automatically; no tests and no conflict handling.", "2026-10-20T10:00:00Z")
        ],
        "expected" => { "status" => "completed", "intent_band" => "below_threshold", "technical_band" => "below_threshold",
                        "readiness" => "not_ready", "rationale" => "Tentative exploration is not explicit direction; an untested spike is not demonstrated feasibility." }
      )
  end

  def explicit_correction_case(id)
    base_case(id, "explicit_correction", "Toolbar navigation model", "Contrasting mouse- and keyboard-oriented interaction clarifies the navigation facet.",
      "keyboard-navigable menus", "Menus open on focus and support full keyboard traversal.").merge(
        "evidence" => [
          evidence("early-hover-statement", "human_statement", "owner", "Hover menus feel natural for the toolbar.", "2026-10-20T09:00:00Z"),
          evidence("keyboard-correction", "human_correction", "owner", "Scrap hover-only: keyboard navigation is required for accessibility.", "2026-10-20T11:00:00Z", supersedes: "early-hover-statement"),
          evidence("menu-primitive-fact", "repository_fact", "agent", "The design system already ships a keyboard-navigable menu primitive.", "2026-10-20T11:30:00Z")
        ],
        "expected" => { "status" => "completed", "intent_band" => "at_or_above_threshold", "technical_band" => "at_or_above_threshold",
                        "readiness" => "ready", "must_cite" => %w[keyboard-correction], "must_not_cite" => %w[early-hover-statement],
                        "rationale" => "A clear correction supersedes the earlier hover direction rather than being outvoted by it." }
      )
  end

  def repeated_agent_suggestions_case(id)
    base_case(id, "repeated_agent_suggestions", "Draft entry surface", "The agent may propose surfaces but cannot invent a preference for them.",
      "command-palette entry", "Open a command palette for creating drafts.").merge(
        "evidence" => [
          evidence("agent-suggestion-1", "agent_suggestion", "agent", "Suggest opening drafts from a command palette.", "2026-10-20T09:00:00Z"),
          evidence("agent-suggestion-2", "agent_suggestion", "agent", "Reiterating: a palette would make draft entry faster.", "2026-10-20T09:05:00Z"),
          evidence("agent-suggestion-3", "agent_suggestion", "agent", "Third proposal for the palette entry point.", "2026-10-20T09:10:00Z"),
          evidence("palette-preview-click", "ui_interaction", "owner", "Previewed the palette prototype once without answering.", "2026-10-20T09:20:00Z")
        ],
        "expected" => { "status" => "unknown", "intent_band" => "unknown", "technical_band" => "at_or_above_threshold",
                        "readiness" => "not_ready",
                        "rationale" => "Repeated agent suggestions and preview interactions are not human agreement; intent stays unknown." }
      )
  end

  def collaborator_disagreement_case(id)
    base_case(id, "collaborator_disagreement", "Default draft visibility", "Whose answers count is attributable; disagreement is not resolved by majority.",
      "team-visible drafts", "Drafts are visible to the whole team by default.").merge(
        "evidence" => [
          evidence("owner-private-statement", "human_statement", "owner", "Drafts should stay private to the author until explicitly shared.", "2026-10-20T09:00:00Z"),
          evidence("collaborator-visible-statement", "human_statement", "collaborator", "No; the whole point of shared drafts is team visibility by default.", "2026-10-20T10:00:00Z"),
          evidence("visibility-flags-fact", "repository_fact", "agent", "Visibility flags for both policies already exist behind the draft API.", "2026-10-20T10:30:00Z")
        ],
        "expected" => { "status" => "clarification_needed", "intent_band" => "unknown", "technical_band" => "at_or_above_threshold",
                        "readiness" => "not_ready",
                        "rationale" => "Conflicting collaborator statements remain attributable and trigger clarification instead of a majority verdict." }
      )
  end

  def unknown_intent_case(id)
    base_case(id, "unknown_intent_strong_technical", "Command palette invocation", "A technically promising prototype is not evidence of wanted behavior.",
      "two-stroke chord invocation", "Invoke the palette with a two-stroke keyboard chord.").merge(
        "evidence" => [
          evidence("chord-proposal", "agent_suggestion", "agent", "Proposed a two-stroke chord invocation for the palette.", "2026-10-20T09:00:00Z"),
          evidence("chord-benchmark", "experiment_result", "agent", "Prototype chord invocation responds in 40ms across the supported browser matrix.", "2026-10-20T10:00:00Z")
        ],
        "expected" => { "status" => "unknown", "intent_band" => "unknown", "technical_band" => "at_or_above_threshold",
                        "readiness" => "not_ready",
                        "rationale" => "Strong technical evidence with no attributable human direction keeps intent unknown; unknown never passes a threshold." }
      )
  end

  def weak_feasibility_case(id)
    base_case(id, "strong_intent_weak_feasibility", "Offline editing", "Human insistence alone does not change technical confidence.",
      "conflict-free offline editing", "Edit fully offline and merge conflict-free on reconnect.").merge(
        "evidence" => [
          evidence("offline-requirement", "human_statement", "owner", "We need full offline editing with no exceptions; I am certain about this.", "2026-10-20T09:00:00Z"),
          evidence("conflict-spike-result", "experiment_result", "agent", "Reconnect spike: last-write-wins loses edits in 3 of 5 simulated conflicts; CRDT evaluation incomplete.", "2026-10-20T10:00:00Z")
        ],
        "expected" => { "status" => "completed", "intent_band" => "at_or_above_threshold", "technical_band" => "below_threshold",
                        "readiness" => "not_ready",
                        "rationale" => "Explicit intent is strong, but the failed conflict spike keeps technical confidence below the threshold." }
      )
  end

  def research_scope_case(id)
    base_case(id, "research_scope", "Invocation recall research", "Research issues need a clear question and feasible method, not a certain implementation answer.",
      "within-subject recall study", "Run a 12-participant within-subject study comparing invocation styles.").merge(
        "evidence" => [
          evidence("research-question", "human_statement", "owner", "Research question: which invocation style has lower recall error? Method: 12-participant within-subject study with a defined error metric.", "2026-10-20T09:00:00Z"),
          evidence("study-harness-fact", "repository_fact", "agent", "An event-capture harness for invocation studies already exists in the research sandbox.", "2026-10-20T09:30:00Z")
        ],
        "expected" => { "status" => "completed", "intent_band" => "at_or_above_threshold", "technical_band" => "at_or_above_threshold",
                        "readiness" => "ready",
                        "rationale" => "A research issue is assessed on the clarity and feasibility of its investigation scope; the implementation option it studies stays uncertain." }
      )
  end

  def boundary_case(id)
    base_case(id, "boundary_79_80", "Export formatting", "The 79/80 boundary keeps each score below its own threshold from passing.",
      "locale-aware CSV export", "Export CSV with locale-aware number formatting.").merge(
        "evidence" => [
          evidence("export-statement", "human_statement", "owner", "CSV export is needed and locale formatting matters, I think; please confirm the decimal separators.", "2026-10-20T09:00:00Z"),
          evidence("formatter-tests", "experiment_result", "agent", "Locale formatter passes the decimal and grouping table tests for all shipped locales.", "2026-10-20T10:00:00Z")
        ],
        "expected" => { "status" => "completed", "intent_band" => "below_threshold", "technical_band" => "at_or_above_threshold",
                        "readiness" => "not_ready",
                        "rationale" => "Intent certainty sits just under the 80 threshold (79) while technical confidence meets it (80); at 80/80 thresholds the issue must stay not ready." }
      )
  end
end
