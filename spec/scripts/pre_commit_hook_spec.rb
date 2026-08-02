# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../support/exec_tmpdir"

# @spec REPO-SECRET-SCAN-001
RSpec.describe "pre-commit hook" do # rubocop:disable RSpec/DescribeClass
  include ExecTmpdir

  it "runs the staged secret scan before linting" do
    # @spec REPO-SECRET-SCAN-001
    Dir.mktmpdir("pre-commit-hook-spec", exec_tmpdir) do |dir|
      hook_path = prepare_fixture(dir)

      stdout, stderr, status = Open3.capture3(base_env(dir), hook_path, chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.read(File.join(dir, "hook-order.log")).lines.map(&:chomp)).to eq([
        "secret-scan --staged",
        "lint --staged"
      ])
    end
  end

  it "blocks before lint when the staged secret scan fails" do
    # @spec REPO-SECRET-SCAN-001
    Dir.mktmpdir("pre-commit-hook-spec", exec_tmpdir) do |dir|
      hook_path = prepare_fixture(dir, secret_scan_status: 1)

      stdout, stderr, status = Open3.capture3(base_env(dir), hook_path, chdir: dir)

      expect(status.success?).to be(false), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.read(File.join(dir, "hook-order.log")).lines.map(&:chomp)).to eq([
        "secret-scan --staged"
      ])
    end
  end

  def prepare_fixture(dir, secret_scan_status: 0)
    FileUtils.mkdir_p(File.join(dir, ".githooks"))
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.mkdir_p(File.join(dir, "stubbin"))

    hook_path = File.join(dir, ".githooks", "pre-commit")
    FileUtils.cp(File.expand_path("../../.githooks/pre-commit", __dir__), hook_path)
    FileUtils.chmod("+x", hook_path)

    write_executable(
      File.join(dir, "bin", "secret-scan"),
      <<~BASH
        #!/usr/bin/env bash
        printf 'secret-scan %s\\n' "$*" >> "#{dir}/hook-order.log"
        exit #{secret_scan_status}
      BASH
    )

    write_executable(
      File.join(dir, "bin", "lint"),
      <<~BASH
        #!/usr/bin/env bash
        printf 'lint %s\\n' "$*" >> "#{dir}/hook-order.log"
      BASH
    )

    write_executable(
      File.join(dir, "stubbin", "git"),
      <<~BASH
        #!/usr/bin/env bash
        if [[ "$1" == "diff" && "$2" == "--cached" && "$3" == "--name-only" ]]; then
          printf 'tracked-file\\n'
          exit 0
        fi

        echo "unexpected git command: $*" >&2
        exit 1
      BASH
    )

    hook_path
  end

  def base_env(dir)
    { "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}" }
  end

  def write_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod("+x", path)
  end
end
