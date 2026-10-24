# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("lib/intent_conformance/shadow_evaluation_worksheet")

# @spec INTENT-CONFORMANCE-ROLLOUT-003
# @spec INTENT-CONFORMANCE-ROLLOUT-008
RSpec.describe IntentConformance::ShadowEvaluationWorksheet, :no_db do
  let(:manifest) { Rails.root.join("tmp/shadow-worksheet-manifest.yml") }
  let(:ledger) { Rails.root.join("tmp/shadow-worksheet-ledger.jsonl") }
  let(:commit) { "a" * 40 }
  let(:base_event) do
    { "manifest_commit" => commit, "manifest_digest" => IntentConformance::ShadowEvaluationLedger.manifest_digest(manifest) }
  end

  before do
    File.write(manifest, { "cases" => [ { "id" => "A-01" }, { "id" => "A-02" } ] }.to_yaml)
    File.delete(ledger) if File.exist?(ledger)
  end

  after { [ manifest, ledger ].each { |path| File.delete(path) if File.exist?(path) } }

  it "computes false alarms, missed material drift, and review cost across an agreeing pair and a tie-broken pair" do
    Dir.mktmpdir do |dir|
      init_git_repo(dir)
      manifest_path = File.join(dir, "manifest.yml")
      ledger_path = File.join(dir, "ledger.jsonl")
      cases = complete_corpus_cases
      manifest_commit = git_write!(dir, manifest_path, { "cases" => cases }.to_yaml, "freeze corpus manifest")
      event_base = { "manifest_commit" => manifest_commit, "manifest_digest" => IntentConformance::ShadowEvaluationLedger.manifest_digest(manifest_path) }

      record_events_in_separate_commits(dir, ledger_path, complete_corpus_events(cases, event_base))

      worksheet = described_class.compile(manifest_path:, ledger_path:, manifest_commit:)

      expect(worksheet).to include("| False alarms | 0.0% (0 / 10) | adjudication + shadow_run |")
      expect(worksheet).to include("| Missed material drift | 10.0% (1 / 10) | adjudication + shadow_run |")
      expect(worksheet).to include("| Review cost | 150 cents | shadow_run |")
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-003
  it "refuses to compile an otherwise complete ledger for an undersized corpus" do
    File.write(manifest, { "cases" => [ complete_case("A-01") ] }.to_yaml)
    File.write(ledger, events_for_single_case.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.compile(manifest_path: manifest, ledger_path: ledger, manifest_commit: commit) }
      .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /at least ten cases in each stratum/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-003
  it "resolves the majority verdict regardless of adjudication order" do
    agreement = [ { "verdict" => "accepted" }, { "verdict" => "accepted" } ]
    tie_break = [ { "verdict" => "accepted" }, { "verdict" => "material_drift" }, { "verdict" => "accepted" } ]

    expect(described_class.majority_verdict(agreement)).to eq("accepted")
    expect(described_class.majority_verdict(tie_break)).to eq("accepted")
    expect(described_class.majority_verdict(tie_break.reverse)).to eq("accepted")
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-005 @spec INTENT-CONFORMANCE-ROLLOUT-008
  it "compiles a solo evaluation with policy provenance, confusion counts, and uncertainty handling" do
    Dir.mktmpdir do |dir|
      init_git_repo(dir)
      manifest_path = File.join(dir, "manifest.yml")
      ledger_path = File.join(dir, "ledger.jsonl")
      cases = complete_corpus_cases
      manifest_commit = git_write!(dir, manifest_path, { "cases" => cases }.to_yaml, "freeze corpus manifest")
      event_base = { "manifest_commit" => manifest_commit, "manifest_digest" => IntentConformance::ShadowEvaluationLedger.manifest_digest(manifest_path) }

      record_events_in_separate_commits(dir, ledger_path, solo_corpus_events(cases, event_base))

      worksheet = described_class.compile(manifest_path:, ledger_path:, manifest_commit:)

      expect(worksheet).to include("solo maintainer maintainer@paid (explicitly selected; no independence")
      expect(worksheet).to include("| Uncertainty handling | 10 uncertain references")
      expect(worksheet).to include("(reference→[within_scope, material_drift, uncertain])")
      expect(worksheet).to include("| False alarms | 0.0% (0 / 10) | adjudication + shadow_run |")
      expect(worksheet).to include("| Missed material drift | 10.0% (1 / 10) | adjudication + shadow_run |")
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-008
  it "lists post-result revisions without letting them change the blinded scores" do
    Dir.mktmpdir do |dir|
      init_git_repo(dir)
      manifest_path = File.join(dir, "manifest.yml")
      ledger_path = File.join(dir, "ledger.jsonl")
      cases = complete_corpus_cases
      manifest_commit = git_write!(dir, manifest_path, { "cases" => cases }.to_yaml, "freeze corpus manifest")
      event_base = { "manifest_commit" => manifest_commit, "manifest_digest" => IntentConformance::ShadowEvaluationLedger.manifest_digest(manifest_path) }

      events = complete_corpus_events(cases, event_base)
      # The maintainer retracts the A-02 reference label after seeing the
      # reviewer's within_scope verdict. The revision is retained evidence,
      # but the missed-drift measure must keep scoring the original label.
      revision = event_base.merge(
        "type" => "label_revision", "event_id" => "rev-a02", "case_id" => "A-02", "operator" => "op-a",
        "original_verdict" => "material_drift", "revised_verdict" => "within_scope",
        "reason" => "reviewer cited a non-binding implementation choice", "recorded_at" => "2026-10-10T10:00:00Z"
      )
      record_events_in_separate_commits(dir, ledger_path, events + [ revision ])

      worksheet = described_class.compile(manifest_path:, ledger_path:, manifest_commit:)

      expect(worksheet).to include("Post-result label revisions (never rescored)")
      expect(worksheet).to include("| A-02 | material_drift | within_scope | reviewer cited a non-binding implementation choice |")
      expect(worksheet).to include("| Missed material drift | 10.0% (1 / 10) | adjudication + shadow_run |")
    end
  end

  def solo_corpus_events(cases, event_base = base_event)
    declaration = event_base.merge("type" => "evaluation_policy", "event_id" => "policy", "policy" => "solo", "maintainer" => "maintainer@paid", "recorded_at" => "2026-10-10T07:00:00Z")
    adjudications = cases.map do |corpus_case|
      verdict = human_verdict_for(corpus_case) == "accepted" ? "within_scope" : human_verdict_for(corpus_case)
      event_base.merge("type" => "adjudication", "event_id" => "#{corpus_case.fetch("id")}-solo", "case_id" => corpus_case.fetch("id"), "operator" => "maintainer@paid", "verdict" => verdict, "cited_design_claim" => "X", "reason" => "Y", "recorded_at" => "2026-10-10T08:01:00Z")
    end
    runs = cases.map { |corpus_case| shadow_run_for(corpus_case, event_base) }
    [ declaration, *adjudications, *runs ]
  end

  def events
    [
      base_event.merge("type" => "operators_frozen", "event_id" => "freeze", "operators" => %w[op-a op-b op-c], "recorded_at" => "2026-10-10T08:00:00Z"),
      # A-01: operators agree (accepted); reviewer correctly says within_scope -> no false alarm.
      base_event.merge("type" => "adjudication", "event_id" => "a01-1", "case_id" => "A-01", "operator" => "op-a", "verdict" => "accepted", "cited_design_claim" => "X", "reason" => "Y", "recorded_at" => "2026-10-10T08:01:00Z"),
      base_event.merge("type" => "adjudication", "event_id" => "a01-2", "case_id" => "A-01", "operator" => "op-b", "verdict" => "accepted", "cited_design_claim" => "X", "reason" => "Y", "recorded_at" => "2026-10-10T08:02:00Z"),
      # A-02: operators disagree and a third breaks the tie toward material_drift; reviewer misses it (within_scope).
      base_event.merge("type" => "adjudication", "event_id" => "a02-1", "case_id" => "A-02", "operator" => "op-a", "verdict" => "material_drift", "cited_design_claim" => "X", "reason" => "Y", "recorded_at" => "2026-10-10T08:03:00Z"),
      base_event.merge("type" => "adjudication", "event_id" => "a02-2", "case_id" => "A-02", "operator" => "op-b", "verdict" => "accepted", "cited_design_claim" => "X", "reason" => "Y", "recorded_at" => "2026-10-10T08:04:00Z"),
      base_event.merge("type" => "adjudication", "event_id" => "a02-3", "case_id" => "A-02", "operator" => "op-c", "verdict" => "material_drift", "cited_design_claim" => "X", "reason" => "Y", "recorded_at" => "2026-10-10T08:05:00Z"),
      base_event.merge("type" => "shadow_run", "event_id" => "run-a01", "case_id" => "A-01", "reviewer_run_id" => "run-1", "reviewer_model" => "model", "prompt_digest" => "digest", "verdict" => "within_scope", "cost_cents" => 100, "recorded_at" => "2026-10-10T09:00:00Z"),
      base_event.merge("type" => "shadow_run", "event_id" => "run-a02", "case_id" => "A-02", "reviewer_run_id" => "run-2", "reviewer_model" => "model", "prompt_digest" => "digest", "verdict" => "within_scope", "cost_cents" => 50, "recorded_at" => "2026-10-10T09:01:00Z")
    ]
  end

  def events_for_single_case
    events.select { |event| event["case_id"] != "A-02" }.map do |event|
      event.merge("event_id" => event.fetch("event_id").sub("a01", "single"))
    end
  end

  def complete_case(id)
    {
      "id" => id,
      "stratum" => "accepted",
      "repository" => "viamin/paid",
      "base_sha" => "a" * 40,
      "head_sha" => "b" * 40,
      "approved_design_revision" => "c" * 40,
      "model" => "reviewer-model",
      "prompt_version" => "review-run-v1"
    }
  end

  def complete_corpus_cases
    accepted = [ complete_case("A-01"), *9.times.map { |index| complete_case("A-#{index + 3}") } ]
    drifted = [ complete_case("A-02"), *9.times.map { |index| complete_case("D-#{index + 1}") } ]
      .map { |item| item.merge("stratum" => "intentionally_drifted") }
    uncertain = 10.times.map { |index| complete_case("U-#{index + 1}").merge("stratum" => "uncertain") }

    [ *accepted, *drifted, *uncertain ]
  end

  def complete_corpus_events(cases, event_base = base_event)
    freeze = event_base.merge("type" => "operators_frozen", "event_id" => "freeze", "operators" => %w[op-a op-b op-c], "recorded_at" => "2026-10-10T08:00:00Z")
    adjudications = cases.flat_map { |corpus_case| adjudications_for(corpus_case, event_base) }
    runs = cases.map { |corpus_case| shadow_run_for(corpus_case, event_base) }
    [ freeze, *adjudications, *runs ]
  end

  def adjudications_for(corpus_case, event_base = base_event)
    verdict = corpus_case.fetch("id") == "A-02" ? "material_drift" : human_verdict_for(corpus_case)
    %w[op-a op-b].map do |operator|
      event_base.merge("type" => "adjudication", "event_id" => "#{corpus_case.fetch("id")}-#{operator}", "case_id" => corpus_case.fetch("id"), "operator" => operator, "verdict" => verdict, "cited_design_claim" => "X", "reason" => "Y", "recorded_at" => "2026-10-10T08:01:00Z")
    end
  end

  def shadow_run_for(corpus_case, event_base = base_event)
    event_base.merge("type" => "shadow_run", "event_id" => "run-#{corpus_case.fetch("id")}", "case_id" => corpus_case.fetch("id"), "reviewer_run_id" => "run-#{corpus_case.fetch("id")}", "reviewer_model" => "model", "prompt_digest" => "digest", "verdict" => reviewer_verdict_for(corpus_case), "cost_cents" => { "A-01" => 100, "A-02" => 50 }.fetch(corpus_case.fetch("id"), 0), "recorded_at" => "2026-10-10T09:00:00Z")
  end

  def human_verdict_for(corpus_case)
    { "accepted" => "accepted", "intentionally_drifted" => "material_drift", "uncertain" => "uncertain" }.fetch(corpus_case.fetch("stratum"))
  end

  def reviewer_verdict_for(corpus_case)
    return "within_scope" if %w[A-01 A-02].include?(corpus_case.fetch("id"))

    corpus_case.fetch("stratum") == "intentionally_drifted" ? "material_drift" : human_verdict_for(corpus_case) == "accepted" ? "within_scope" : "uncertain"
  end

  def record_events_in_separate_commits(dir, path, events)
    first_event, *remaining_events = events
    git_write!(dir, path, "#{JSON.generate(first_event)}\n", "record #{first_event.fetch("event_id")}")
    remaining_events.each { |event| git_append_events!(dir, path, [ event ], "record #{event.fetch("event_id")}") }
  end
end
