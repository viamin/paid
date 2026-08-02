# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../support/exec_tmpdir"

# @spec REPO-SECRET-SCAN-001, REPO-SECRET-SCAN-002
RSpec.describe "bin/secret-scan" do # rubocop:disable RSpec/DescribeClass
  include ExecTmpdir

  it "runs Gitleaks protect against staged changes" do
    # @spec REPO-SECRET-SCAN-001
    Dir.mktmpdir("secret-scan-spec", exec_tmpdir) do |dir|
      script_path = prepare_fixture(dir)
      env = { "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}" }

      stdout, stderr, status = Open3.capture3(env, script_path, "--staged", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.read(File.join(dir, "gitleaks-invocations.log")).lines.map(&:chomp)).to eq([
        "protect --staged --redact --no-banner"
      ])
    end
  end

  it "runs Gitleaks against repository contents for audit mode" do
    # @spec REPO-SECRET-SCAN-002
    Dir.mktmpdir("secret-scan-spec", exec_tmpdir) do |dir|
      script_path = prepare_fixture(dir)
      env = { "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}" }

      stdout, stderr, status = Open3.capture3(env, script_path, "--repo", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.read(File.join(dir, "gitleaks-invocations.log")).lines.map(&:chomp)).to eq([
        "dir --redact --no-banner --config #{dir}/.gitleaks.toml --gitleaks-ignore-path #{dir}/.gitleaksignore ."
      ])
    end
  end

  def prepare_fixture(dir)
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.mkdir_p(File.join(dir, "stubbin"))
    FileUtils.cp(File.expand_path("../../bin/secret-scan", __dir__), File.join(dir, "bin", "secret-scan"))
    FileUtils.chmod("+x", File.join(dir, "bin", "secret-scan"))
    File.write(File.join(dir, ".gitleaks.toml"), "title = 'test'\n")
    File.write(File.join(dir, ".gitleaksignore"), "")
    FileUtils.mkdir_p(File.join(dir, "app"))
    File.write(File.join(dir, "app", "tracked.rb"), "puts 'tracked'\n")

    write_executable(
      File.join(dir, "bin", "install-gitleaks"),
      <<~BASH
        #!/usr/bin/env bash
        printf '%s\\n' "#{dir}/bin/fake-gitleaks"
      BASH
    )

    write_executable(
      File.join(dir, "bin", "fake-gitleaks"),
      <<~BASH
        #!/usr/bin/env bash
        printf '%s\\n' "$*" >> "#{dir}/gitleaks-invocations.log"
      BASH
    )

    write_executable(
      File.join(dir, "stubbin", "git"),
      <<~BASH
        #!/usr/bin/env bash
        if [[ "$1" == "ls-files" && "$2" == "-z" ]]; then
          printf 'app/tracked.rb\\0'
          exit 0
        fi

        echo "unexpected git command: $*" >&2
        exit 1
      BASH
    )

    File.join(dir, "bin", "secret-scan")
  end

  def write_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod("+x", path)
  end
end
