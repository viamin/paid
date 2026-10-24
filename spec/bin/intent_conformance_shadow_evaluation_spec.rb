# frozen_string_literal: true

require "rails_helper"
require "digest"
require "open3"
require "tmpdir"

# @spec INTENT-CONFORMANCE-ROLLOUT-002
# @spec INTENT-CONFORMANCE-ROLLOUT-003
RSpec.describe "bin/intent-conformance-shadow-evaluation" do # rubocop:disable RSpec/DescribeClass
  let(:script_path) { File.expand_path("../../bin/intent-conformance-shadow-evaluation", __dir__) }
  let(:commit) { "a" * 40 }

  # The CLI runs as a plain `ruby` subprocess with no Rails/ActiveSupport loaded
  # (see bin/intent-conformance-shadow-evaluation), unlike the lib specs which run
  # under rails_helper. This is the only coverage that exercises that constraint.
  it "compiles a worksheet from a complete ledger without relying on ActiveSupport core extensions" do
    Dir.mktmpdir do |dir|
      manifest = File.join(dir, "manifest.yml")
      ledger = File.join(dir, "ledger.jsonl")
      cases = complete_corpus_cases
      File.write(manifest, { "cases" => cases }.to_yaml)
      manifest_commit = commit_fixture_file(dir, manifest, "freeze corpus manifest")
      complete_ledger_events(cases, manifest, manifest_commit).each do |event|
        File.open(ledger, "a") { |file| file.puts(JSON.generate(event)) }
        commit_fixture_file(dir, ledger, "append #{event.fetch("event_id")}")
      end

      stdout, stderr, status = run_cli("compile", "--manifest", manifest, "--ledger", ledger, "--manifest-commit", manifest_commit)

      expect(status.exitstatus).to eq(0), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("| Review cost | 100 cents | shadow_run |")
    end
  end

  it "stamps the append event with the requested frozen manifest commit" do
    Dir.mktmpdir do |dir|
      manifest = File.join(dir, "manifest.yml")
      ledger = File.join(dir, "ledger.jsonl")
      File.write(manifest, { "cases" => [ { "id" => "A-01" } ] }.to_yaml)

      _stdout, stderr, status = run_cli("append", "--manifest", manifest, "--ledger", ledger, "--manifest-commit", commit,
        "--event", JSON.generate({ "event_id" => "event-1", "recorded_at" => "2026-10-10T08:00:00Z", "manifest_commit" => "b" * 40 }))

      expect(status.exitstatus).to eq(0), -> { "stderr: #{stderr}" }
      expect(JSON.parse(File.read(ledger)).fetch("manifest_commit")).to eq(commit)
    end
  end

  it "rejects an empty frozen manifest commit before appending" do
    Dir.mktmpdir do |dir|
      manifest = File.join(dir, "manifest.yml")
      ledger = File.join(dir, "ledger.jsonl")
      File.write(manifest, { "cases" => [ { "id" => "A-01" } ] }.to_yaml)

      _stdout, stderr, status = run_cli("append", "--manifest", manifest, "--ledger", ledger, "--manifest-commit", "",
        "--event", JSON.generate({ "event_id" => "event-1", "recorded_at" => "2026-10-10T08:00:00Z" }))

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("--manifest-commit is required")
      expect(File).not_to exist(ledger)
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "prints usage for a bare invocation before validating flags" do
    _stdout, stderr, status = run_cli

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("usage:")
    expect(stderr).not_to include("--manifest is required")
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "reports malformed append JSON without a backtrace" do
    Dir.mktmpdir do |dir|
      manifest = File.join(dir, "manifest.yml")
      ledger = File.join(dir, "ledger.jsonl")
      File.write(manifest, { "cases" => [ { "id" => "A-01" } ] }.to_yaml)

      _stdout, stderr, status = run_cli("append", "--manifest", manifest, "--ledger", ledger, "--manifest-commit", commit, "--event", "{bad json")

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("invalid shadow-evaluation ledger: --event is not valid JSON")
      expect(stderr).not_to include("bin/intent-conformance-shadow-evaluation:")
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "rejects non-object append JSON without a backtrace" do
    Dir.mktmpdir do |dir|
      manifest = File.join(dir, "manifest.yml")
      ledger = File.join(dir, "ledger.jsonl")
      File.write(manifest, { "cases" => [ { "id" => "A-01" } ] }.to_yaml)

      [ "[1,2]", "42", '"text"' ].each do |event|
        _stdout, stderr, status = run_cli("append", "--manifest", manifest, "--ledger", ledger, "--manifest-commit", commit, "--event", event)

        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("invalid shadow-evaluation ledger: --event must be a JSON object")
        expect(stderr).not_to include("bin/intent-conformance-shadow-evaluation:")
      end
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "round-trips non-ASCII event content under the US-ASCII default locale" do
    # The system locale is C/POSIX (US-ASCII default external encoding) on this
    # image. The ledger normalizes its file reads and writes to UTF-8 so
    # adjudicator reason text such as the section mark in cited_design_claim
    # survives a validate cycle on the same disk file.
    Dir.mktmpdir do |dir|
      manifest = File.join(dir, "manifest.yml")
      ledger = File.join(dir, "ledger.jsonl")
      File.write(manifest, { "cases" => [ { "id" => "A-01" } ] }.to_yaml)
      manifest_commit = commit_fixture_file(dir, manifest, "freeze")

      stdout, stderr, status = run_cli("append", "--manifest", manifest, "--ledger", ledger, "--manifest-commit", manifest_commit,
        "--event", JSON.generate({ "event_id" => "freeze", "type" => "operators_frozen", "operators" => %w[op-a op-b], "recorded_at" => "2026-10-13T08:00:00Z", "cited_design_claim" => "RDR-067 §Materiality boundary" }))
      expect(status.exitstatus).to eq(0), -> { "stderr: #{stderr}" }
      expect(stdout).to be_empty

      commit_fixture_file(dir, ledger, "append freeze")

      # The pending-human-input exit code (2) proves the JSON parsed cleanly
      # under the US-ASCII default locale — without the UTF-8 normalization
      # the same call would crash with Encoding::InvalidByteSequenceError and
      # an exit code of 1.
      stdout, stderr, status = run_cli("validate", "--manifest", manifest, "--ledger", ledger, "--manifest-commit", manifest_commit)
      expect(status.exitstatus).to eq(2), -> { "stderr: #{stderr}" }
      expect(stderr).to include("pending human input")
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "reports malformed options without a backtrace" do
    _stdout, stderr, status = run_cli("validate", "--unknown")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("invalid shadow-evaluation ledger: invalid option: --unknown")
    expect(stderr).not_to include("bin/intent-conformance-shadow-evaluation:")
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  it "reports a missing manifest without a backtrace" do
    Dir.mktmpdir do |dir|
      missing_manifest = File.join(dir, "missing.yml")
      ledger = File.join(dir, "ledger.jsonl")

      _stdout, stderr, status = run_cli("validate", "--manifest", missing_manifest, "--ledger", ledger, "--manifest-commit", commit)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("invalid shadow-evaluation ledger: invalid corpus manifest:")
      expect(stderr).not_to include("bin/intent-conformance-shadow-evaluation:")
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-005
  it "records an explicitly selected solo policy declaration with its maintainer" do
    Dir.mktmpdir do |dir|
      manifest = File.join(dir, "manifest.yml")
      ledger = File.join(dir, "ledger.jsonl")
      File.write(manifest, { "cases" => [ { "id" => "A-01" } ] }.to_yaml)

      _stdout, stderr, status = run_cli("init", "--manifest", manifest, "--ledger", ledger, "--manifest-commit", commit,
        "--policy", "solo", "--maintainer", "maintainer@paid")

      expect(status.exitstatus).to eq(0), -> { "stderr: #{stderr}" }
      declaration = JSON.parse(File.read(ledger))
      expect(declaration).to include("type" => "evaluation_policy", "policy" => "solo", "maintainer" => "maintainer@paid")
      expect(declaration.fetch("manifest_commit")).to eq(commit)
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-005
  it "refuses a solo declaration without a maintainer and an unknown policy" do
    Dir.mktmpdir do |dir|
      manifest = File.join(dir, "manifest.yml")
      ledger = File.join(dir, "ledger.jsonl")
      File.write(manifest, { "cases" => [ { "id" => "A-01" } ] }.to_yaml)

      _stdout, stderr, status = run_cli("init", "--manifest", manifest, "--ledger", ledger, "--manifest-commit", commit, "--policy", "solo")
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("--maintainer is required for the solo policy")

      _stdout, stderr, status = run_cli("init", "--manifest", manifest, "--ledger", ledger, "--manifest-commit", commit,
        "--policy", "auto", "--maintainer", "maintainer@paid")
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("--policy must be one of team|solo")
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-007
  it "points shadow-run at the documented execute command instead of presenting validation as execution" do
    Dir.mktmpdir do |dir|
      manifest = File.join(dir, "manifest.yml")
      ledger = File.join(dir, "ledger.jsonl")
      cases = complete_corpus_cases
      File.write(manifest, { "cases" => cases }.to_yaml)
      manifest_commit = commit_fixture_file(dir, manifest, "freeze corpus manifest")

      solo_ledger_events(cases, manifest, manifest_commit).each do |event|
        File.open(ledger, "a") { |file| file.puts(JSON.generate(event)) }
        commit_fixture_file(dir, ledger, "append #{event.fetch("event_id")}")
      end

      _stdout, stderr, status = run_cli("shadow-run", "--manifest", manifest, "--ledger", ledger, "--manifest-commit", manifest_commit)

      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("nothing has executed")
      expect(stderr).to include("intent_conformance:shadow_evaluation:execute")
    end
  end

  def solo_ledger_events(cases, manifest, manifest_commit)
    base = { "manifest_commit" => manifest_commit, "manifest_digest" => Digest::SHA256.file(manifest).hexdigest }
    declaration = base.merge("type" => "evaluation_policy", "event_id" => "policy", "policy" => "solo", "maintainer" => "maintainer@paid", "recorded_at" => "2026-10-10T07:00:00Z")
    adjudications = cases.map do |corpus_case|
      base.merge("type" => "adjudication", "event_id" => "#{corpus_case.fetch("id")}-solo", "case_id" => corpus_case.fetch("id"), "operator" => "maintainer@paid", "verdict" => "within_scope", "cited_design_claim" => "X", "reason" => "Y", "recorded_at" => "2026-10-10T08:01:00Z")
    end
    [ declaration, *adjudications ]
  end

  def complete_ledger_events(cases, manifest, manifest_commit)
    base = { "manifest_commit" => manifest_commit, "manifest_digest" => Digest::SHA256.file(manifest).hexdigest }
    freeze = base.merge("type" => "operators_frozen", "event_id" => "freeze", "operators" => %w[op-a op-b], "recorded_at" => "2026-10-10T08:00:00Z")
    adjudications = cases.flat_map { |corpus_case| adjudications_for(base, corpus_case) }
    runs = cases.map { |corpus_case| shadow_run_for(base, corpus_case) }

    [ freeze, *adjudications, *runs ]
  end

  def complete_corpus_cases
    %w[accepted intentionally_drifted uncertain].flat_map do |stratum|
      10.times.map { |index| complete_case("#{stratum}-#{index}", stratum) }
    end
  end

  def complete_case(id, stratum)
    { "id" => id, "stratum" => stratum, "repository" => "viamin/paid", "base_sha" => "a" * 40, "head_sha" => "b" * 40, "approved_design_revision" => "c" * 40, "model" => "reviewer-model", "prompt_version" => "review-run-v1" }
  end

  def adjudications_for(base, corpus_case)
    verdict = corpus_case.fetch("stratum") == "intentionally_drifted" ? "material_drift" : corpus_case.fetch("stratum")
    %w[op-a op-b].map do |operator|
      base.merge("type" => "adjudication", "event_id" => "#{corpus_case.fetch("id")}-#{operator}", "case_id" => corpus_case.fetch("id"), "operator" => operator, "verdict" => verdict, "cited_design_claim" => "X", "reason" => "Y", "recorded_at" => "2026-10-10T08:01:00Z")
    end
  end

  def shadow_run_for(base, corpus_case)
    stratum = corpus_case.fetch("stratum")
    verdict = { "accepted" => "within_scope", "intentionally_drifted" => "material_drift", "uncertain" => "uncertain" }.fetch(stratum)
    cost = stratum == "accepted" && corpus_case.fetch("id").end_with?("-0") ? 100 : 0

    base.merge("type" => "shadow_run", "event_id" => "run-#{corpus_case.fetch("id")}", "case_id" => corpus_case.fetch("id"), "reviewer_run_id" => "run-#{corpus_case.fetch("id")}", "reviewer_model" => "model", "prompt_digest" => "digest", "verdict" => verdict, "cost_cents" => cost, "recorded_at" => "2026-10-10T09:00:00Z")
  end

  def run_cli(*args)
    Open3.capture3({ "LC_ALL" => "C", "LANG" => "C" }, "ruby", script_path, *args)
  end

  def commit_fixture_file(directory, path, message)
    run_git(directory, "init") unless File.exist?(File.join(directory, ".git"))
    run_git(directory, "add", path)
    run_git(directory, "-c", "user.name=Spec User", "-c", "user.email=spec@example.test", "commit", "-m", message)
    stdout, = run_git(directory, "rev-parse", "HEAD")
    stdout.strip
  end

  def run_git(directory, *args)
    stdout, stderr, status = Open3.capture3("git", "-C", directory, *args)
    raise "git fixture setup failed: #{stderr}" unless status.success?

    [ stdout, stderr, status ]
  end
end
