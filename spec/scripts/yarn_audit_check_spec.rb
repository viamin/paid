# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "../support/exec_tmpdir"

# @spec REPO-DEPENDENCY-AUDIT-001, REPO-DEPENDENCY-AUDIT-002,
# @spec REPO-DEPENDENCY-AUDIT-003, REPO-DEPENDENCY-AUDIT-004,
# @spec REPO-DEPENDENCY-AUDIT-005, REPO-DEPENDENCY-AUDIT-007
RSpec.describe "bin/yarn-audit-check" do # rubocop:disable RSpec/DescribeClass
  include ExecTmpdir

  let(:future_date) { (Date.today + 30).iso8601 }
  let(:today_date) { Date.today.iso8601 }
  let(:past_date) { (Date.today - 1).iso8601 }

  it "exits zero when the allowlist is empty and yarn audit reports no advisories" do
    # @spec REPO-DEPENDENCY-AUDIT-001
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      prepare_workspace(dir, allowlist: empty_allowlist, yarn_output: empty_yarn_output)

      stdout, stderr, status = Open3.capture3(env(dir), script_path(dir), chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("advisories reported: 0")
      expect(stdout).to include("blocking: 0")
      expect(File.read(File.join(dir, "yarn-invocations.log")).lines.map(&:chomp)).to eq([
        "audit --json"
      ])
    end
  end

  it "exits non-zero when yarn audit reports an advisory not covered by the allowlist" do
    # @spec REPO-DEPENDENCY-AUDIT-001
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      prepare_workspace(
        dir,
        allowlist: empty_allowlist,
        yarn_output: yarn_advisory_output(ghsa_id: "GHSA-xxxx-yyyy-zzzz", module_name: "demo-pkg"),
        yarn_exit: 1
      )

      stdout, stderr, status = Open3.capture3(env(dir), script_path(dir), chdir: dir)

      expect(status.exitstatus).to eq(1), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stderr).to include("yarn audit reported 1 uncovered advisory")
      expect(stderr).not_to include("scanner failed")
      expect(stdout).to include("blocking findings:")
      expect(stdout).to include("GHSA-xxxx-yyyy-zzzz (high) demo-pkg")
    end
  end

  it "exits zero and surfaces an accepted advisory when the allowlist covers it, even though yarn exits 1 for the advisory report" do
    # @spec REPO-DEPENDENCY-AUDIT-004
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      prepare_workspace(
        dir,
        allowlist: allowlist_with(future_date: future_date, ghsa_id: "GHSA-xxxx-yyyy-zzzz"),
        yarn_output: yarn_advisory_output(ghsa_id: "GHSA-xxxx-yyyy-zzzz", module_name: "demo-pkg"),
        yarn_exit: 1
      )

      stdout, stderr, status = Open3.capture3(env(dir), script_path(dir), chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stderr).not_to include("scanner failed")
      expect(stdout).to include("accepted (allowlisted): 1")
      expect(stdout).to include("blocking: 0")
      expect(stdout).to include("GHSA-xxxx-yyyy-zzzz (high) demo-pkg@1.0.0 expires #{future_date}")
    end
  end

  it "fails the run with exit 3 when an allowlist entry has expired" do
    # @spec REPO-DEPENDENCY-AUDIT-003
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      prepare_workspace(
        dir,
        allowlist: allowlist_with(future_date: past_date, ghsa_id: "GHSA-xxxx-yyyy-zzzz"),
        yarn_output: yarn_advisory_output(ghsa_id: "GHSA-xxxx-yyyy-zzzz", module_name: "demo-pkg")
      )

      _stdout, stderr, status = Open3.capture3(env(dir), script_path(dir), chdir: dir)

      expect(status.exitstatus).to eq(3)
      expect(stderr).to include("expired on #{past_date}")
    end
  end

  it "accepts an allowlist entry that expires today" do
    # @spec REPO-DEPENDENCY-AUDIT-003
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      prepare_workspace(
        dir,
        allowlist: allowlist_with(future_date: today_date, ghsa_id: "GHSA-xxxx-yyyy-zzzz"),
        yarn_output: yarn_advisory_output(ghsa_id: "GHSA-xxxx-yyyy-zzzz", module_name: "demo-pkg"),
        yarn_exit: 1
      )

      _stdout, _stderr, status = Open3.capture3(env(dir), script_path(dir), chdir: dir)

      expect(status.success?).to be(true)
    end
  end

  it "fails the run with exit 3 when the allowlist root is not a mapping" do
    # @spec REPO-DEPENDENCY-AUDIT-003
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      prepare_workspace(dir, allowlist: "# No exceptions remain.\n", yarn_output: empty_yarn_output)

      _stdout, stderr, status = Open3.capture3(env(dir), script_path(dir), chdir: dir)

      expect(status.exitstatus).to eq(3)
      expect(stderr).to include("must be a YAML mapping with an `exceptions` list")
    end
  end

  it "fails the run with exit 3 when exceptions is not a list" do
    # @spec REPO-DEPENDENCY-AUDIT-003
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      prepare_workspace(dir, allowlist: "exceptions: GHSA-xxxx-yyyy-zzzz\n", yarn_output: empty_yarn_output)

      _stdout, stderr, status = Open3.capture3(env(dir), script_path(dir), chdir: dir)

      expect(status.exitstatus).to eq(3)
      expect(stderr).to include("must have an `exceptions` list")
    end
  end

  it "fails the run when an allowlist entry is missing a required field" do
    # @spec REPO-DEPENDENCY-AUDIT-003
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      broken_allowlist = <<~YAML
        exceptions:
          - id: GHSA-xxxx-yyyy-zzzz
            module: demo-pkg
            owner: "@paid/test"
            expires_on: 2099-01-01
            tracking_issue: "#1"
      YAML
      prepare_workspace(dir, allowlist: broken_allowlist, yarn_output: empty_yarn_output)

      _stdout, stderr, status = Open3.capture3(env(dir), script_path(dir), chdir: dir)

      expect(status.exitstatus).to eq(3)
      expect(stderr).to include("missing required field(s): reason")
    end
  end

  it "fails the run when an allowlist id does not match the GHSA format" do
    # @spec REPO-DEPENDENCY-AUDIT-003
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      broken_allowlist = <<~YAML
        exceptions:
          - id: not-a-ghsa-id
            module: demo-pkg
            reason: "test"
            owner: "@paid/test"
            expires_on: 2099-01-01
            tracking_issue: "#1"
      YAML
      prepare_workspace(dir, allowlist: broken_allowlist, yarn_output: empty_yarn_output)

      _stdout, stderr, status = Open3.capture3(env(dir), script_path(dir), chdir: dir)

      expect(status.exitstatus).to eq(3)
      expect(stderr).to include("expected GHSA-...")
    end
  end

  it "fails the run when an allowlist id is duplicated" do
    # @spec REPO-DEPENDENCY-AUDIT-003
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      duplicate_allowlist = <<~YAML
        exceptions:
          - id: GHSA-aaaa-bbbb-cccc
            module: pkg-a
            reason: "first"
            owner: "@paid/test"
            expires_on: 2099-01-01
            tracking_issue: "#1"
          - id: GHSA-aaaa-bbbb-cccc
            module: pkg-a
            reason: "second"
            owner: "@paid/test"
            expires_on: 2099-01-01
            tracking_issue: "#2"
      YAML
      prepare_workspace(dir, allowlist: duplicate_allowlist, yarn_output: empty_yarn_output)

      _stdout, stderr, status = Open3.capture3(env(dir), script_path(dir), chdir: dir)

      expect(status.exitstatus).to eq(3)
      expect(stderr).to include("duplicated")
    end
  end

  it "fails the run when the allowlist file is missing" do
    # @spec REPO-DEPENDENCY-AUDIT-003
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      prepare_workspace(dir, allowlist: nil, yarn_output: empty_yarn_output)

      _stdout, stderr, status = Open3.capture3(env(dir), script_path(dir), chdir: dir)

      expect(status.exitstatus).to eq(3)
      expect(stderr).to include("allowlist not found")
    end
  end

  it "fails the run with a scanner-error message when yarn emits an error event" do
    # @spec REPO-DEPENDENCY-AUDIT-002
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      scanner_error_output = [
        JSON.generate(type: "error", data: "could not reach registry.npmjs.org"),
        JSON.generate(type: "auditSummary", data: { vulnerabilities: {}, dependencies: 1 })
      ].join("\n")
      prepare_workspace(dir, allowlist: empty_allowlist, yarn_output: scanner_error_output)

      _stdout, stderr, status = Open3.capture3(env(dir), script_path(dir), chdir: dir)

      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("yarn audit scanner failed")
      expect(stderr).to include("could not reach registry.npmjs.org")
    end
  end

  it "fails the run when yarn exits non-zero without emitting a JSON error event" do
    # @spec REPO-DEPENDENCY-AUDIT-002
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      prepare_workspace(
        dir,
        allowlist: empty_allowlist,
        yarn_output: "",
        yarn_stderr: "yarn command failed before producing audit output",
        yarn_exit: 1
      )

      _stdout, stderr, status = Open3.capture3(env(dir), script_path(dir), chdir: dir)

      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("yarn audit scanner failed")
      expect(stderr).to include("yarn command failed before producing audit output")
    end
  end

  it "fails the run when yarn emits unparseable JSON instead of advisories" do
    # @spec REPO-DEPENDENCY-AUDIT-002
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      prepare_workspace(dir, allowlist: empty_allowlist, yarn_output: "{broken-json")

      _stdout, stderr, status = Open3.capture3(env(dir), script_path(dir), chdir: dir)

      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("could not parse yarn audit JSON output")
    end
  end

  it "fails the run as a scanner failure when yarn exits non-zero with a summary but no advisory report" do
    # @spec REPO-DEPENDENCY-AUDIT-002
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      prepare_workspace(dir, allowlist: empty_allowlist, yarn_output: empty_yarn_output, yarn_exit: 1)

      _stdout, stderr, status = Open3.capture3(env(dir), script_path(dir), chdir: dir)

      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("yarn audit scanner failed")
    end
  end

  it "fails the run as a scanner failure when the yarn binary cannot be executed" do
    # @spec REPO-DEPENDENCY-AUDIT-002
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      prepare_workspace(dir, allowlist: empty_allowlist, yarn_output: empty_yarn_output)
      # A broken interpreter makes execve fail (ENOENT) without the PATH
      # search falling through to another yarn on PATH.
      File.write(File.join(dir, "stubbin", "yarn"), "#!/nonexistent/interpreter\n")

      _stdout, stderr, status = Open3.capture3(env(dir), script_path(dir), chdir: dir)

      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("yarn audit scanner failed")
      expect(stderr).to include("could not run yarn audit")
    end
  end

  it "writes the accepted report with an ISO date even when the allowlist quotes expires_on" do
    # @spec REPO-DEPENDENCY-AUDIT-004
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      report_path = File.join(dir, "yarn-audit-accepted.json")
      prepare_workspace(
        dir,
        allowlist: allowlist_with(future_date: future_date, ghsa_id: "GHSA-xxxx-yyyy-zzzz").gsub("expires_on: #{future_date}", "expires_on: \"#{future_date}\""),
        yarn_output: yarn_advisory_output(ghsa_id: "GHSA-xxxx-yyyy-zzzz", module_name: "demo-pkg"),
        yarn_exit: 1
      )

      _stdout, _stderr, status = run_with_report_env(dir, report_path)

      expect(status.success?).to be(true)
      expect(JSON.parse(File.read(report_path))).to eq([
        expected_accepted_row(ghsa_id: "GHSA-xxxx-yyyy-zzzz", expires_on: future_date)
      ])
    end
  end

  it "blocks an advisory when its allowlist entry names a different module" do
    # @spec REPO-DEPENDENCY-AUDIT-004
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      prepare_workspace(
        dir,
        allowlist: allowlist_with(future_date: future_date, ghsa_id: "GHSA-xxxx-yyyy-zzzz", module_name: "other-pkg"),
        yarn_output: yarn_advisory_output(ghsa_id: "GHSA-xxxx-yyyy-zzzz", module_name: "demo-pkg"),
        yarn_exit: 1
      )

      stdout, stderr, status = Open3.capture3(env(dir), script_path(dir), chdir: dir)

      expect(status.exitstatus).to eq(1), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("blocking findings:")
      expect(stdout).to include("demo-pkg")
    end
  end

  it "writes structured accepted rows to YARN_AUDIT_ACCEPTED_REPORT when set" do
    # @spec REPO-DEPENDENCY-AUDIT-004
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      report_path = File.join(dir, "yarn-audit-accepted.json")
      prepare_workspace(
        dir,
        allowlist: allowlist_with(future_date: future_date, ghsa_id: "GHSA-xxxx-yyyy-zzzz"),
        yarn_output: yarn_advisory_output(ghsa_id: "GHSA-xxxx-yyyy-zzzz", module_name: "demo-pkg"),
        yarn_exit: 1
      )

      _stdout, _stderr, status = run_with_report_env(dir, report_path)

      expect(status.success?).to be(true)
      expect(JSON.parse(File.read(report_path))).to eq([
        expected_accepted_row(ghsa_id: "GHSA-xxxx-yyyy-zzzz", expires_on: future_date)
      ])
    end
  end

  it "writes an empty accepted report when nothing is accepted" do
    # @spec REPO-DEPENDENCY-AUDIT-004
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      report_path = File.join(dir, "yarn-audit-accepted.json")
      prepare_workspace(dir, allowlist: empty_allowlist, yarn_output: empty_yarn_output)

      _stdout, _stderr, status = run_with_report_env(dir, report_path)

      expect(status.success?).to be(true)
      expect(JSON.parse(File.read(report_path))).to eq([])
    end
  end

  it "does not write an accepted report on a scanner failure" do
    # @spec REPO-DEPENDENCY-AUDIT-002
    Dir.mktmpdir("yarn-audit-check-spec", exec_tmpdir) do |dir|
      report_path = File.join(dir, "yarn-audit-accepted.json")
      prepare_workspace(
        dir,
        allowlist: empty_allowlist,
        yarn_output: "",
        yarn_stderr: "yarn command failed before producing audit output",
        yarn_exit: 1
      )

      _stdout, _stderr, status = run_with_report_env(dir, report_path)

      expect(status.exitstatus).to eq(2)
      expect(File.exist?(report_path)).to be(false)
    end
  end

  def env(dir)
    { "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}" }
  end

  def run_with_report_env(dir, report_path)
    Open3.capture3(
      env(dir).merge("YARN_AUDIT_ACCEPTED_REPORT" => report_path),
      script_path(dir),
      chdir: dir
    )
  end

  def expected_accepted_row(ghsa_id:, expires_on:)
    {
      "id" => ghsa_id,
      "module" => "demo-pkg",
      "installed_version" => "1.0.0",
      "severity" => "high",
      "expires_on" => expires_on,
      "owner" => "@paid/test",
      "tracking_issue" => "#1"
    }
  end

  def script_path(dir)
    File.join(dir, "bin", "yarn-audit-check")
  end

  def prepare_workspace(dir, allowlist:, yarn_output:, yarn_stderr: "", yarn_exit: 0)
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.mkdir_p(File.join(dir, "stubbin"))
    FileUtils.mkdir_p(File.join(dir, "config", "security"))

    FileUtils.cp(
      File.expand_path("../../bin/yarn-audit-check", __dir__),
      script_path(dir)
    )
    FileUtils.chmod("+x", script_path(dir))

    if allowlist
      File.write(File.join(dir, "config", "security", "yarn-audit-allowlist.yml"), allowlist)
    end

    File.write(
      File.join(dir, "stubbin", "yarn"),
      <<~BASH
        #!/usr/bin/env bash
        printf '%s\\n' "$*" >> "#{dir}/yarn-invocations.log"
        printf '%s\\n' "$(cat "#{File.join(dir, 'yarn-output.txt')}")"
        printf '%s\\n' "$(cat "#{File.join(dir, 'yarn-stderr.txt')}")" >&2
        exit #{yarn_exit}
      BASH
    )
    FileUtils.chmod("+x", File.join(dir, "stubbin", "yarn"))
    File.write(File.join(dir, "yarn-output.txt"), yarn_output)
    File.write(File.join(dir, "yarn-stderr.txt"), yarn_stderr)
  end

  def empty_allowlist
    <<~YAML
      exceptions: []
    YAML
  end

  def empty_yarn_output
    JSON.generate(type: "auditSummary", data: { vulnerabilities: {}, dependencies: 0 })
  end

  def yarn_advisory_output(ghsa_id:, module_name:)
    advisory = {
      type: "auditAdvisory",
      data: {
        resolution: { id: 1, path: "somepath>#{module_name}" },
        advisory: {
          findings: [ { version: "1.0.0", paths: [ "somepath>#{module_name}" ] } ],
          github_advisory_id: ghsa_id,
          module_name: module_name,
          severity: "high",
          title: "Demo advisory",
          recommendation: "Upgrade to 2.0.0",
          vulnerable_versions: "<2.0.0",
          patched_versions: ">=2.0.0"
        }
      }
    }
    summary = JSON.generate(type: "auditSummary", data: { vulnerabilities: {}, dependencies: 1 })
    "#{JSON.generate(advisory)}\n#{summary}"
  end

  def allowlist_with(future_date:, ghsa_id:, module_name: "demo-pkg")
    <<~YAML
      exceptions:
        - id: #{ghsa_id}
          module: #{module_name}
          reason: "Test reason"
          owner: "@paid/test"
          expires_on: #{future_date}
          tracking_issue: "#1"
    YAML
  end
end
