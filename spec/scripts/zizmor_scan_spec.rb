# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "psych"
require "tmpdir"
require_relative "../support/exec_tmpdir"

# @spec REPO-WORKFLOW-SCAN-001, REPO-WORKFLOW-SCAN-002
RSpec.describe "bin/zizmor-scan" do # rubocop:disable RSpec/DescribeClass
  include ExecTmpdir

  it "scans .github/workflows with the pinned Zizmor binary and passes through a clean result" do
    # @spec REPO-WORKFLOW-SCAN-001
    Dir.mktmpdir("zizmor-scan-spec", exec_tmpdir) do |dir|
      script_path = prepare_fixture(dir, zizmor_exit: 0)

      stdout, stderr, status = Open3.capture3(script_path, chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.read(File.join(dir, "zizmor-invocations.log")).lines.map(&:chomp)).to eq([
        ".github/workflows"
      ])
    end
  end

  it "fails when Zizmor reports a workflow security finding" do
    # @spec REPO-WORKFLOW-SCAN-002
    Dir.mktmpdir("zizmor-scan-spec", exec_tmpdir) do |dir|
      script_path = prepare_fixture(dir, zizmor_exit: 1)

      _stdout, stderr, status = Open3.capture3(script_path, chdir: dir)

      expect(status.success?).to be(false)
      expect(stderr).to include("Zizmor found workflow security issues")
    end
  end

  it "retries the workflow scan before surfacing a failure" do
    workflow = Psych.safe_load_file(File.expand_path("../../.github/workflows/security.yml", __dir__), aliases: true)
    scan_step = workflow.fetch("jobs").fetch("workflow-scan").fetch("steps")
      .find { |step| step["name"] == "Scan GitHub Actions workflows with Zizmor" }

    expect(scan_step.fetch("run")).to include(
      "for attempt in 1 2 3",
      "Workflow scan failed (attempt $attempt/3); retrying",
      "exit 1"
    )
  end

  it "restores the version-sensitive Gitleaks cache before the audit" do
    # @spec REPO-SECRET-SCAN-002
    workflow = Psych.safe_load_file(File.expand_path("../../.github/workflows/security.yml", __dir__), aliases: true)
    steps = workflow.fetch("jobs").fetch("audit").fetch("steps")
    cache_step = steps.find { |step| step["name"] == "Restore pinned Gitleaks binary" }

    expect(cache_step).to include(
      "uses" => "actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
      "with" => {
        "path" => "tmp/tools/gitleaks",
        "key" => "gitleaks-${{ runner.os }}-${{ hashFiles('bin/install-gitleaks') }}"
      }
    )
    expect(steps.index(cache_step)).to be < steps.index(steps.find { |step| step["name"] == "Run security audit and secret scan" })
  end

  def prepare_fixture(dir, zizmor_exit:)
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.cp(File.expand_path("../../bin/zizmor-scan", __dir__), File.join(dir, "bin", "zizmor-scan"))
    FileUtils.chmod("+x", File.join(dir, "bin", "zizmor-scan"))

    write_executable(
      File.join(dir, "bin", "install-zizmor"),
      <<~BASH
        #!/usr/bin/env bash
        printf '%s\\n' "#{dir}/bin/fake-zizmor"
      BASH
    )

    write_executable(
      File.join(dir, "bin", "fake-zizmor"),
      <<~BASH
        #!/usr/bin/env bash
        printf '%s\\n' "$*" >> "#{dir}/zizmor-invocations.log"
        exit #{zizmor_exit}
      BASH
    )

    File.join(dir, "bin", "zizmor-scan")
  end

  def write_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod("+x", path)
  end
end
