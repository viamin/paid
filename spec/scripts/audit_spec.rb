# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../support/exec_tmpdir"

# @spec REPO-DEPENDENCY-AUDIT-001, REPO-DEPENDENCY-AUDIT-002,
# @spec REPO-DEPENDENCY-AUDIT-006
RSpec.describe "bin/audit" do # rubocop:disable RSpec/DescribeClass
  include ExecTmpdir

  it "delegates to bin/yarn-audit-check after the other audit tools and only prints success when yarn audit passes" do
    # @spec REPO-DEPENDENCY-AUDIT-006
    Dir.mktmpdir("audit-spec", exec_tmpdir) do |dir|
      script_path = prepare_fixture(dir)

      stdout, _stderr, status = Open3.capture3(env(dir), script_path, chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}" }
      invocations = File.read(File.join(dir, "audit-invocations.log")).lines.map(&:chomp)
      expect(invocations).to eq([
        "secret-scan --repo",
        "brakeman --quiet --no-pager --exit-on-warn --exit-on-error",
        "bundler-audit ",
        "yarn-audit-check"
      ])
      expect(stdout).to include("All security checks passed.")
    end
  end

  it "fails the suite when bin/yarn-audit-check fails so a finding or scanner error never reports as passed" do
    # @spec REPO-DEPENDENCY-AUDIT-001, REPO-DEPENDENCY-AUDIT-002
    Dir.mktmpdir("audit-spec", exec_tmpdir) do |dir|
      script_path = prepare_fixture(dir, yarn_audit_exit: 1)

      _stdout, _stderr, status = Open3.capture3(env(dir), script_path, chdir: dir)

      expect(status.success?).to be(false)
      invocations = File.read(File.join(dir, "audit-invocations.log")).lines.map(&:chomp)
      expect(invocations).to include("yarn-audit-check")
    end
  end

  def env(dir)
    { "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}" }
  end

  def prepare_fixture(dir, yarn_audit_exit: 0)
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.mkdir_p(File.join(dir, "stubbin"))

    audit_path = File.join(dir, "bin", "audit")
    FileUtils.cp(File.expand_path("../../bin/audit", __dir__), audit_path)
    FileUtils.chmod("+x", audit_path)

    %w[secret-scan brakeman bundler-audit].each do |tool|
      write_executable(
        File.join(dir, "bin", tool),
        <<~BASH
          #!/usr/bin/env bash
          joined="$*"
          printf '%s\\n' "#{tool} ${joined}" >> "#{dir}/audit-invocations.log"
        BASH
      )
    end

    # bin/audit invokes bin/yarn-audit-check from the repository root. Stub it
    # here so the test can verify that its exit status propagates through the
    # suite without invoking Yarn.
    write_executable(
      File.join(dir, "bin", "yarn-audit-check"),
      <<~BASH
        #!/usr/bin/env bash
        printf '%s\\n' "yarn-audit-check" >> "#{dir}/audit-invocations.log"
        exit #{yarn_audit_exit}
      BASH
    )

    audit_path
  end

  def write_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod("+x", path)
  end
end
