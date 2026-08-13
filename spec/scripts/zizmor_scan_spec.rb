# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
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
