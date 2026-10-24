# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("lib/intent_conformance/shadow_evaluation_ledger")

RSpec.describe IntentConformance::ShadowEvaluationLedger, :no_db do
  let(:manifest) { Rails.root.join("tmp/shadow-manifest.yml") }
  let(:ledger) { Rails.root.join("tmp/shadow-ledger.jsonl") }
  let(:base_event) do
    { "manifest_commit" => "a" * 40, "manifest_digest" => described_class.manifest_digest(manifest), "recorded_at" => "2026-10-10T12:00:00Z" }
  end

  before do
    File.write(manifest, { "cases" => [ { "id" => "A-01" } ] }.to_yaml)
    File.delete(ledger) if File.exist?(ledger)
  end

  after { [ manifest, ledger ].each { |path| File.delete(path) if File.exist?(path) } }

  it "refuses shadow execution while adjudications are absent" do
    expect { described_class.ready_for_shadow_run!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(IntentConformance::ShadowEvaluationLedger::PendingHumanInput, /pending human input/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "refuses an otherwise adjudicated corpus that lacks the required rollout shape" do
    File.write(manifest, { "cases" => [ complete_case("A-01") ] }.to_yaml)
    File.write(ledger, complete_adjudication_events.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.ready_for_shadow_run!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /at least ten cases in each stratum/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "refuses a full corpus case without repository and reviewer identity" do
    cases = complete_corpus_cases
    cases.first.delete("prompt_version")
    File.write(manifest, { "cases" => cases }.to_yaml)
    File.write(ledger, complete_corpus_adjudication_events(cases).map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.ready_for_shadow_run!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /model\/prompt identity/)
  end

  it "rejects non-independent paired adjudications" do
    events = [
      base_event.merge("type" => "operators_frozen", "event_id" => "freeze", "operators" => %w[one two three]),
      base_event.merge("type" => "adjudication", "event_id" => "one", "case_id" => "A-01", "operator" => "one", "verdict" => "accepted", "cited_design_claim" => "X", "reason" => "Y"),
      base_event.merge("type" => "adjudication", "event_id" => "two", "case_id" => "A-01", "operator" => "one", "verdict" => "accepted", "cited_design_claim" => "X", "reason" => "Y")
    ]
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))
    expect { described_class.ready_for_shadow_run!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }.to raise_error(/independent/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "rejects an operator freeze appended after an adjudication even when backdated" do
    events = complete_adjudication_events.drop(1) + [
      base_event.merge("type" => "operators_frozen", "event_id" => "freeze", "operators" => %w[one two three], "recorded_at" => "2026-10-10T11:00:00Z")
    ]
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.ready_for_shadow_run!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(/operators_frozen event must precede adjudications/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "rejects a replacement operator freeze appended after adjudications" do
    events = complete_adjudication_events + [
      base_event.merge("type" => "operators_frozen", "event_id" => "replacement-freeze", "operators" => %w[one two three])
    ]
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.ready_for_shadow_run!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(/operators_frozen event must precede adjudications/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "rejects a tie-break after the primary adjudicators agree" do
    events = complete_adjudication_events + [
      base_event.merge("type" => "adjudication", "event_id" => "three", "case_id" => "A-01", "operator" => "three", "verdict" => "material_drift", "cited_design_claim" => "X", "reason" => "Y")
    ]
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.ready_for_shadow_run!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(/must not have a tie-break after agreement/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-003
  it "rejects a tie-break verdict that matches neither primary verdict" do
    events = [
      base_event.merge("type" => "operators_frozen", "event_id" => "freeze", "operators" => %w[one two three]),
      base_event.merge("type" => "adjudication", "event_id" => "one", "case_id" => "A-01", "operator" => "one", "verdict" => "accepted", "cited_design_claim" => "X", "reason" => "Y"),
      base_event.merge("type" => "adjudication", "event_id" => "two", "case_id" => "A-01", "operator" => "two", "verdict" => "material_drift", "cited_design_claim" => "X", "reason" => "Y"),
      base_event.merge("type" => "adjudication", "event_id" => "three", "case_id" => "A-01", "operator" => "three", "verdict" => "uncertain", "cited_design_claim" => "X", "reason" => "Y")
    ]
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.ready_for_shadow_run!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(/tie-break verdict must agree with one of the primary verdicts/)
  end

  it "rejects a requested manifest identity that differs from ledger events" do
    File.write(ledger, JSON.generate(base_event.merge("type" => "adjudication", "event_id" => "one")))
    expect { described_class.ready_for_shadow_run!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "b" * 40) }.to raise_error(/every ledger event/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "rejects a manifest whose content was edited after adjudication while keeping the same manifest_commit label" do
    Dir.mktmpdir do |dir|
      init_git_repo(dir)
      manifest_path = File.join(dir, "manifest.yml")
      ledger_path = File.join(dir, "ledger.jsonl")
      cases = complete_corpus_cases
      manifest_commit = git_write!(dir, manifest_path, { "cases" => cases }.to_yaml, "freeze corpus manifest")
      base = event_base_for(manifest_path, manifest_commit)

      record_events_in_separate_commits(dir, ledger_path, complete_corpus_adjudication_events(cases, base) + complete_corpus_shadow_runs(cases, base))

      expect(described_class.validate!(manifest_path: manifest_path, ledger_path: ledger_path, manifest_commit: manifest_commit)).to be(true)

      tampered_cases = cases.dup
      tampered_cases[0] = tampered_cases[0].merge("head_sha" => "f" * 40)
      File.write(manifest_path, { "cases" => tampered_cases }.to_yaml)

      expect { described_class.validate!(manifest_path: manifest_path, ledger_path: ledger_path, manifest_commit: manifest_commit) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /must match the frozen corpus manifest content/)
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "rejects a manifest_commit that does not resolve to a real git commit" do
    Dir.mktmpdir do |dir|
      init_git_repo(dir)
      manifest_path = File.join(dir, "manifest.yml")
      ledger_path = File.join(dir, "ledger.jsonl")
      cases = complete_corpus_cases
      git_write!(dir, manifest_path, { "cases" => cases }.to_yaml, "freeze corpus manifest")
      base = event_base_for(manifest_path, "a" * 40)

      git_write!(dir, ledger_path, complete_corpus_adjudication_events(cases, base).map { |event| JSON.generate(event) }.join("\n"), "record adjudications")
      git_append_events!(dir, ledger_path, complete_corpus_shadow_runs(cases, base), "record shadow runs")

      expect { described_class.validate!(manifest_path: manifest_path, ledger_path: ledger_path, manifest_commit: "a" * 40) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /not a commit reachable in this repository/)
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "rejects a manifest_commit that exists in git but never held the frozen manifest content" do
    Dir.mktmpdir do |dir|
      init_git_repo(dir)
      manifest_path = File.join(dir, "manifest.yml")
      ledger_path = File.join(dir, "ledger.jsonl")
      cases = complete_corpus_cases
      unrelated_commit = git_write!(dir, File.join(dir, "unrelated.txt"), "irrelevant", "unrelated commit")
      File.write(manifest_path, { "cases" => cases }.to_yaml)
      base = event_base_for(manifest_path, unrelated_commit)

      git_write!(dir, ledger_path, complete_corpus_adjudication_events(cases, base).map { |event| JSON.generate(event) }.join("\n"), "record adjudications")
      git_append_events!(dir, ledger_path, complete_corpus_shadow_runs(cases, base), "record shadow runs")

      expect { described_class.validate!(manifest_path: manifest_path, ledger_path: ledger_path, manifest_commit: unrelated_commit) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /does not contain the frozen corpus manifest content/)
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "rejects a ledger whose entire freeze/adjudication/shadow-run sequence was recorded in a single commit" do
    Dir.mktmpdir do |dir|
      init_git_repo(dir)
      manifest_path = File.join(dir, "manifest.yml")
      ledger_path = File.join(dir, "ledger.jsonl")
      cases = complete_corpus_cases
      manifest_commit = git_write!(dir, manifest_path, { "cases" => cases }.to_yaml, "freeze corpus manifest")
      base = event_base_for(manifest_path, manifest_commit)
      events = complete_corpus_adjudication_events(cases, base) + complete_corpus_shadow_runs(cases, base)

      git_write!(dir, ledger_path, events.map { |event| JSON.generate(event) }.join("\n"), "record entire sequence after the fact")

      expect { described_class.validate!(manifest_path: manifest_path, ledger_path: ledger_path, manifest_commit: manifest_commit) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /each ledger event must be introduced by a separate git commit/)
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "rejects multiple events introduced together after an earlier ledger commit" do
    Dir.mktmpdir do |dir|
      init_git_repo(dir)
      manifest_path = File.join(dir, "manifest.yml")
      ledger_path = File.join(dir, "ledger.jsonl")
      cases = complete_corpus_cases
      manifest_commit = git_write!(dir, manifest_path, { "cases" => cases }.to_yaml, "freeze corpus manifest")
      base = event_base_for(manifest_path, manifest_commit)
      adjudications = complete_corpus_adjudication_events(cases, base)
      shadow_runs = complete_corpus_shadow_runs(cases, base)

      git_write!(dir, ledger_path, JSON.generate(adjudications.shift), "record first adjudication")
      git_append_events!(dir, ledger_path, adjudications + shadow_runs, "fabricate remaining events together")

      expect { described_class.validate!(manifest_path: manifest_path, ledger_path: ledger_path, manifest_commit: manifest_commit) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /each ledger event must be introduced by a separate git commit/)
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "rejects a committed rewrite of an earlier ledger event" do
    Dir.mktmpdir do |dir|
      init_git_repo(dir)
      manifest_path = File.join(dir, "manifest.yml")
      ledger_path = File.join(dir, "ledger.jsonl")
      cases = complete_corpus_cases
      manifest_commit = git_write!(dir, manifest_path, { "cases" => cases }.to_yaml, "freeze corpus manifest")
      base = event_base_for(manifest_path, manifest_commit)
      events = complete_corpus_adjudication_events(cases, base) + complete_corpus_shadow_runs(cases, base)

      record_events_in_separate_commits(dir, ledger_path, events)
      rewritten_events = File.readlines(ledger_path)
      rewritten_event = JSON.parse(rewritten_events.fetch(1)).merge("reason" => "rewritten after adjudication")
      rewritten_events[1] = "#{JSON.generate(rewritten_event)}\n"
      git_write!(dir, ledger_path, rewritten_events.join, "rewrite prior adjudication")

      expect { described_class.validate!(manifest_path: manifest_path, ledger_path: ledger_path, manifest_commit: manifest_commit) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /append exactly one event/)
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "rejects a ledger commit that does not descend from the frozen manifest commit" do
    Dir.mktmpdir do |dir|
      init_git_repo(dir)
      manifest_path = File.join(dir, "manifest.yml")
      ledger_path = File.join(dir, "ledger.jsonl")
      cases = complete_corpus_cases

      run_git(dir, "checkout", "-q", "--orphan", "manifest-branch")
      manifest_commit = git_write!(dir, manifest_path, { "cases" => cases }.to_yaml, "freeze corpus manifest")

      run_git(dir, "checkout", "-q", "--orphan", "ledger-branch")
      File.write(manifest_path, { "cases" => cases }.to_yaml)
      base = event_base_for(manifest_path, manifest_commit)
      record_events_in_separate_commits(dir, ledger_path, complete_corpus_adjudication_events(cases, base) + complete_corpus_shadow_runs(cases, base))

      expect { described_class.validate!(manifest_path: manifest_path, ledger_path: ledger_path, manifest_commit: manifest_commit) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /does not descend from the frozen manifest commit/)
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "rejects an adjudication that references a case outside the frozen manifest" do
    events = complete_adjudication_events + [
      base_event.merge("type" => "adjudication", "event_id" => "typo", "case_id" => "TYPO-CASE", "operator" => "three", "verdict" => "bogus_verdict", "cited_design_claim" => "X", "reason" => "Y")
    ]
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.ready_for_shadow_run!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /adjudication references a case outside the frozen manifest/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "rejects any event whose manifest commit differs from the frozen manifest" do
    events = complete_adjudication_events + [
      base_event.merge("type" => "shadow_run", "event_id" => "run", "case_id" => "A-01", "reviewer_run_id" => "run-1", "reviewer_model" => "model", "prompt_digest" => "digest", "verdict" => "within_scope", "cost_cents" => 1, "manifest_commit" => "b" * 40)
    ]
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.validate!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(/every ledger event/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "rejects events that omit the frozen manifest commit" do
    events = complete_adjudication_events
    events.last.delete("manifest_commit")
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.ready_for_shadow_run!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(/every ledger event/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "rejects reviewer runs recorded before adjudications are complete" do
    run = base_event.merge("type" => "shadow_run", "event_id" => "run", "case_id" => "A-01", "reviewer_run_id" => "run-1", "reviewer_model" => "model", "prompt_digest" => "digest", "verdict" => "within_scope", "cost_cents" => 1)
    events = complete_adjudication_events.insert(1, run)
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.validate!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(/before adjudications completed/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "rejects reviewer runs timestamped before adjudications are complete" do
    events = complete_adjudication_events + [
      base_event.merge("type" => "shadow_run", "event_id" => "run", "case_id" => "A-01", "reviewer_run_id" => "run-1", "reviewer_model" => "model", "prompt_digest" => "digest", "verdict" => "within_scope", "cost_cents" => 1, "recorded_at" => "2026-10-10T11:59:00Z")
    ]
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.validate!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(/timestamped before adjudications completed/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "accepts reviewer runs appended and timestamped after complete adjudications" do
    Dir.mktmpdir do |dir|
      init_git_repo(dir)
      manifest_path = File.join(dir, "manifest.yml")
      ledger_path = File.join(dir, "ledger.jsonl")
      cases = complete_corpus_cases
      manifest_commit = git_write!(dir, manifest_path, { "cases" => cases }.to_yaml, "freeze corpus manifest")
      base = event_base_for(manifest_path, manifest_commit)

      record_events_in_separate_commits(dir, ledger_path, complete_corpus_adjudication_events(cases, base) + complete_corpus_shadow_runs(cases, base))

      expect(described_class.validate!(manifest_path: manifest_path, ledger_path: ledger_path, manifest_commit: manifest_commit)).to be(true)
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-003
  it "rejects a shadow run with hollow reviewer evidence" do
    events = complete_adjudication_events + [
      base_event.merge("type" => "shadow_run", "event_id" => "run", "case_id" => "A-01", "reviewer_run_id" => "", "reviewer_model" => "", "prompt_digest" => "", "verdict" => "within_scope", "cost_cents" => nil, "recorded_at" => "2026-10-10T12:01:00Z")
    ]
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.validate!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /shadow run lacks reviewer identity/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "rejects duplicate event IDs already present in the ledger" do
    events = complete_adjudication_events
    events.last["event_id"] = "one"
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.ready_for_shadow_run!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /event_id already exists/)
  end

  it "rejects an empty corpus manifest file" do
    File.write(manifest, "")
    expect { described_class.load_manifest(manifest) }.to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /expected a mapping with a cases list/)
  end

  it "rejects a corpus manifest that is a YAML sequence instead of a mapping" do
    File.write(manifest, [ "foo", "bar" ].to_yaml)
    expect { described_class.load_manifest(manifest) }.to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /expected a mapping with a cases list/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "rejects an empty corpus manifest" do
    File.write(manifest, { "cases" => [] }.to_yaml)

    expect { described_class.load_manifest(manifest) }
      .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /cases list must not be empty/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "reports a missing corpus manifest as invalid input" do
    missing_manifest = Rails.root.join("tmp/missing-shadow-manifest.yml")
    File.delete(missing_manifest) if File.exist?(missing_manifest)

    expect { described_class.load_manifest(missing_manifest) }
      .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /invalid corpus manifest/)
  end

  it "rejects a corpus manifest case that is missing an id" do
    File.write(manifest, { "cases" => [ { "stratum" => "accepted" } ] }.to_yaml)
    expect { described_class.load_manifest(manifest) }.to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /every case needs an id/)
  end

  it "rejects duplicate corpus manifest case IDs" do
    File.write(manifest, { "cases" => [ { "id" => "A-01" }, { "id" => "A-01" } ] }.to_yaml)
    expect { described_class.load_manifest(manifest) }.to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /case ids must be unique/)
  end

  # The UI Start path shares this single corpus-shape definition with the CLI
  # surfaces, so neither can accept a corpus the other rejects (#4598 review).
  it "validates the corpus shape a manifest must satisfy before an evaluation starts" do
    File.write(manifest, { "cases" => complete_corpus_cases }.to_yaml)
    expect(described_class.validate_corpus_shape!(manifest)).to be(true)

    File.write(manifest, { "cases" => complete_corpus_cases.first(29) }.to_yaml)
    expect { described_class.validate_corpus_shape!(manifest) }
      .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /at least ten cases in each stratum/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-003
  it "rejects a shadow run referencing a case outside the frozen manifest" do
    events = complete_adjudication_events + [
      base_event.merge("type" => "shadow_run", "event_id" => "run", "case_id" => "TYPO-CASE", "reviewer_run_id" => "run-1", "reviewer_model" => "model", "prompt_digest" => "digest", "verdict" => "within_scope", "cost_cents" => 9999, "recorded_at" => "2026-10-10T12:01:00Z")
    ]
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.validate!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /outside the frozen manifest/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-003
  it "rejects more than one shadow run for the same case" do
    events = complete_adjudication_events + [
      base_event.merge("type" => "shadow_run", "event_id" => "run-1", "case_id" => "A-01", "reviewer_run_id" => "run-1", "reviewer_model" => "model", "prompt_digest" => "digest", "verdict" => "within_scope", "cost_cents" => 1, "recorded_at" => "2026-10-10T12:01:00Z"),
      base_event.merge("type" => "shadow_run", "event_id" => "run-2", "case_id" => "A-01", "reviewer_run_id" => "run-2", "reviewer_model" => "model", "prompt_digest" => "digest", "verdict" => "material_drift", "cost_cents" => 1, "recorded_at" => "2026-10-10T12:02:00Z")
    ]
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.validate!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /at most one shadow run/)
  end

  it "refuses worksheet compilation until human input and reviewer events exist" do
    require Rails.root.join("lib/intent_conformance/shadow_evaluation_worksheet")
    expect {
      IntentConformance::ShadowEvaluationWorksheet.compile(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40)
    }.to raise_error(IntentConformance::ShadowEvaluationLedger::PendingHumanInput, /pending human input/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-005
  it "validates a solo ledger: declaration first, one maintainer adjudication per case, then runs" do
    Dir.mktmpdir do |dir|
      init_git_repo(dir)
      manifest_path = File.join(dir, "manifest.yml")
      ledger_path = File.join(dir, "ledger.jsonl")
      cases = complete_corpus_cases
      manifest_commit = git_write!(dir, manifest_path, { "cases" => cases }.to_yaml, "freeze corpus manifest")
      base = event_base_for(manifest_path, manifest_commit)

      record_events_in_separate_commits(dir, ledger_path, solo_corpus_events(cases, base))

      expect(described_class.validate!(manifest_path: manifest_path, ledger_path: ledger_path, manifest_commit: manifest_commit)).to be(true)
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-005
  it "does not reinterpret a declaration-less ledger as solo evidence: the team policy still demands two operators" do
    # Emulates the rejected 2026-10-13 bot-authored ledger shape: a frozen
    # operator list plus a single operator's adjudication and no policy
    # declaration — the team rules, not a solo reading, apply.
    File.write(manifest, { "cases" => [ complete_case("A-01") ] }.to_yaml)
    single = [
      base_event.merge("type" => "operators_frozen", "event_id" => "freeze", "operators" => %w[maintainer@paid second@paid]),
      base_event.merge("type" => "adjudication", "event_id" => "one", "case_id" => "A-01", "operator" => "maintainer@paid", "verdict" => "within_scope", "cited_design_claim" => "X", "reason" => "Y")
    ]
    File.write(ledger, single.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.ready_for_shadow_run!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(IntentConformance::ShadowEvaluationLedger::PendingHumanInput, /A-01 needs two adjudications/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-005
  it "rejects a solo adjudication by an operator other than the declared maintainer" do
    File.write(manifest, { "cases" => complete_corpus_cases }.to_yaml)
    events = solo_corpus_events(complete_corpus_cases)
    events[1] = events[1].merge("operator" => "paid-agents@paid-agents.com")
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.ready_for_shadow_run!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /declared maintainer/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-008
  it "rejects a solo label revision recorded before the case's reviewer run" do
    cases = complete_corpus_cases
    File.write(manifest, { "cases" => cases }.to_yaml)
    events = solo_corpus_events(cases)
    revision = base_event.merge(
      "type" => "label_revision", "event_id" => "rev-early", "case_id" => events[1].fetch("case_id"),
      "operator" => "maintainer@paid", "original_verdict" => events[1].fetch("verdict"), "revised_verdict" => "uncertain",
      "reason" => "rethought", "recorded_at" => "2026-10-10T11:00:00Z"
    )
    # Insert before every shadow run but after the adjudications.
    insert_at = events.index { |event| event["type"] == "shadow_run" }
    events.insert(insert_at, revision)
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.validate!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /label revision must follow the case's shadow run/)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-005
  it "keeps a skipped solo case as pending human input instead of completed evidence" do
    cases = complete_corpus_cases
    File.write(manifest, { "cases" => cases }.to_yaml)
    skipped_case = cases.first.fetch("id")
    events = solo_corpus_events(cases)
    events.reject! { |event| event["type"] == "adjudication" && event["case_id"] == skipped_case }
    events << base_event.merge("type" => "case_skipped", "event_id" => "skip-1", "case_id" => skipped_case, "operator" => "maintainer@paid", "recorded_at" => "2026-10-10T12:00:00Z")
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))

    expect { described_class.ready_for_shadow_run!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(IntentConformance::ShadowEvaluationLedger::PendingHumanInput, /needs the maintainer's blinded label/)
  end

  def solo_corpus_events(cases, event_base = base_event)
    declaration = event_base.merge("type" => "evaluation_policy", "event_id" => "policy", "policy" => "solo", "maintainer" => "maintainer@paid", "recorded_at" => "2026-10-10T07:00:00Z")
    adjudications = cases.map do |corpus_case|
      event_base.merge("type" => "adjudication", "event_id" => "#{corpus_case.fetch("id")}-solo", "case_id" => corpus_case.fetch("id"), "operator" => "maintainer@paid", "verdict" => "within_scope", "cited_design_claim" => "X", "reason" => "Y", "recorded_at" => "2026-10-10T08:01:00Z")
    end
    runs = cases.map do |corpus_case|
      event_base.merge("type" => "shadow_run", "event_id" => "run-#{corpus_case.fetch("id")}", "case_id" => corpus_case.fetch("id"), "reviewer_run_id" => "run-#{corpus_case.fetch("id")}", "reviewer_model" => "model", "prompt_digest" => "digest", "verdict" => "within_scope", "cost_cents" => 1, "recorded_at" => "2026-10-10T12:01:00Z")
    end
    [ declaration, *adjudications, *runs ]
  end

  def complete_adjudication_events
    [
      base_event.merge("type" => "operators_frozen", "event_id" => "freeze", "operators" => %w[one two three]),
      base_event.merge("type" => "adjudication", "event_id" => "one", "case_id" => "A-01", "operator" => "one", "verdict" => "accepted", "cited_design_claim" => "X", "reason" => "Y"),
      base_event.merge("type" => "adjudication", "event_id" => "two", "case_id" => "A-01", "operator" => "two", "verdict" => "accepted", "cited_design_claim" => "X", "reason" => "Y")
    ]
  end

  def event_base_for(manifest_path, manifest_commit)
    base_event.merge("manifest_commit" => manifest_commit, "manifest_digest" => described_class.manifest_digest(manifest_path))
  end

  def complete_case(id, stratum: "accepted")
    {
      "id" => id,
      "stratum" => stratum,
      "repository" => "viamin/paid",
      "base_sha" => "a" * 40,
      "head_sha" => "b" * 40,
      "approved_design_revision" => "c" * 40,
      "model" => "reviewer-model",
      "prompt_version" => "review-run-v1"
    }
  end

  def complete_corpus_cases
    %w[accepted intentionally_drifted uncertain].flat_map do |stratum|
      10.times.map { |index| complete_case("#{stratum}-#{index}", stratum:) }
    end
  end

  def complete_corpus_adjudication_events(cases, event_base = base_event)
    freeze = event_base.merge("type" => "operators_frozen", "event_id" => "freeze", "operators" => %w[one two])
    adjudications = cases.flat_map do |corpus_case|
      [ "one", "two" ].map do |operator|
        event_base.merge("type" => "adjudication", "event_id" => "#{corpus_case.fetch("id")}-#{operator}", "case_id" => corpus_case.fetch("id"), "operator" => operator, "verdict" => "accepted", "cited_design_claim" => "X", "reason" => "Y")
      end
    end
    [ freeze, *adjudications ]
  end

  def complete_corpus_shadow_runs(cases, event_base = base_event)
    cases.map do |corpus_case|
      event_base.merge("type" => "shadow_run", "event_id" => "run-#{corpus_case.fetch("id")}", "case_id" => corpus_case.fetch("id"), "reviewer_run_id" => "run-#{corpus_case.fetch("id")}", "reviewer_model" => "model", "prompt_digest" => "digest", "verdict" => "within_scope", "cost_cents" => 1, "recorded_at" => "2026-10-10T12:01:00Z")
    end
  end

  def record_events_in_separate_commits(dir, path, events)
    first_event, *remaining_events = events
    git_write!(dir, path, "#{JSON.generate(first_event)}\n", "record #{first_event.fetch("event_id")}")
    remaining_events.each { |event| git_append_events!(dir, path, [ event ], "record #{event.fetch("event_id")}") }
  end
end
