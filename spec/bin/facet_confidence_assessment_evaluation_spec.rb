# frozen_string_literal: true

require "rails_helper"
require "json"
require "open3"
require "tmpdir"

require Rails.root.join("lib/facet_confidence/assessment_corpus_ledger")

# @spec FACET-CONFIDENCE-016 @spec FACET-CONFIDENCE-017
# @spec FACET-CONFIDENCE-018
RSpec.describe "bin/facet-confidence-assessment-evaluation" do # rubocop:disable RSpec/DescribeClass
  let(:script_path) { File.expand_path("../../bin/facet-confidence-assessment-evaluation", __dir__) }
  let(:committed_corpus) { File.expand_path("../../docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml", __dir__) }
  let(:corpus_dir) { Pathname.new(Dir.mktmpdir) }
  let(:corpus) { corpus_dir.join("corpus.yml").to_s }
  let(:ledger) { corpus_dir.join("ledger.jsonl").to_s }

  after { corpus_dir.rmtree if corpus_dir.exist? }

  it "validates the committed corpus manifest and an empty ledger" do
    _stdout, stderr, status = run_cli("validate", "--corpus", committed_corpus, "--ledger", ledger)

    expect(status.exitstatus).to eq(0), -> { "stderr: #{stderr}" }
  end

  it "prints usage for a bare invocation before validating flags" do
    _stdout, stderr, status = run_cli

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("usage:")
  end

  it "stamps appended events with the frozen corpus version and digest" do
    copy_committed_corpus

    _stdout, _stderr, status = run_cli("append", "--corpus", corpus, "--ledger", ledger,
      "--event", JSON.generate({ "event_id" => "event-1", "recorded_at" => "2026-10-23T09:00:00Z", "type" => "assessment_run" }))

    expect(status.exitstatus).to eq(0)
    event = JSON.parse(File.read(ledger))
    expect(event).to include("corpus_version" => "facet-confidence-corpus-v1")
    expect(event).to include("corpus_digest" => FacetConfidence::AssessmentCorpusLedger.corpus_digest(corpus))
  end

  it "reports malformed append JSON without a backtrace" do
    copy_committed_corpus

    _stdout, stderr, status = run_cli("append", "--corpus", corpus, "--ledger", ledger, "--event", "{bad json")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("invalid assessment corpus ledger: --event is not valid JSON")
    expect(stderr).not_to include("bin/facet-confidence-assessment-evaluation:")
  end

  it "exits pending-operator-input when compiling before every corpus case has a run" do
    copy_committed_corpus

    _stdout, stderr, status = run_cli("compile", "--corpus", corpus, "--ledger", ledger)

    expect(status.exitstatus).to eq(2)
    expect(stderr).to include("pending operator input: every corpus case needs at least one assessment run")
  end

  it "compiles the outcome worksheet for a fully covered ledger" do
    copy_committed_corpus
    append_complete_ledger!

    stdout, stderr, status = run_cli("compile", "--corpus", corpus, "--ledger", ledger)

    expect(status.exitstatus).to eq(0), -> { "stderr: #{stderr}" }
    expect(stdout).to include("| False readiness |")
    expect(stdout).to include("| Unnecessary clarification |")
    expect(stdout).to include("| Human corrections |")
    expect(stdout).to include("| Assessment cost |")
    expect(stdout).to include("| Downstream rework |")
    expect(stdout).to include("| Operational failures |")
    expect(stdout).to include("Threshold or rubric tuning proposals must cite the outcome metrics above")
  end

  def copy_committed_corpus
    File.write(corpus, File.read(committed_corpus))
  end

  def append_complete_ledger!
    cases = FacetConfidence::AssessmentCorpusLedger.load_corpus(corpus)
    identity = { "corpus_version" => "facet-confidence-corpus-v1", "corpus_digest" => FacetConfidence::AssessmentCorpusLedger.corpus_digest(corpus) }
    cases.each do |corpus_case|
      expected = corpus_case.fetch("expected")
      completed = expected.fetch("status") == "completed"
      thresholds = corpus_case.fetch("thresholds")
      run_event = identity.merge("event_id" => "run-#{corpus_case.fetch('id')}", "recorded_at" => "2026-10-23T09:00:00Z",
        "type" => "assessment_run", "case_id" => corpus_case.fetch("id"),
        "rubric_version" => "facet-confidence-v1", "model_version" => "claude-sonnet-4-6",
        "input_revision" => corpus_case.fetch("evidence_revision"), "status" => expected.fetch("status"),
        "intent_score" => completed ? band_score(expected.fetch("intent_band"), thresholds.fetch("intent")) : nil,
        "technical_score" => completed ? band_score(expected.fetch("technical_band"), thresholds.fetch("technical")) : nil,
        "evidence_references" => run_references(corpus_case), "cost_cents" => 100)
      File.open(ledger, "a") { |file| file.puts(JSON.generate(run_event)) }
    end
  end

  def band_score(band, threshold)
    { "unknown" => nil, "below_threshold" => threshold - 1, "at_or_above_threshold" => threshold }.fetch(band)
  end

  def run_references(corpus_case)
    expected = corpus_case.fetch("expected")
    references = corpus_case.fetch("evidence").map { |evidence| evidence.fetch("reference") } - Array(expected["must_not_cite"])
    expected["must_cite"].present? ? expected["must_cite"] : references
  end

  def run_cli(*args)
    Open3.capture3({ "LC_ALL" => "C", "LANG" => "C" }, "ruby", script_path, *args)
  end
end
