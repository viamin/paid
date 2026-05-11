# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../support/exec_tmpdir"

RSpec.describe "bin/setup" do # rubocop:disable RSpec/DescribeClass
  include ExecTmpdir

  let(:script_source) { File.expand_path("../../bin/setup", __dir__) }
  let(:log_truncator_source) { File.expand_path("../../lib/paid/log_truncator.rb", __dir__) }

  it "starts bin/dev detached with restart-if-running when server startup is enabled" do
    Dir.mktmpdir("setup-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      env = {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "WORKSPACE_ROOT" => File.join(dir, "workspace-root")
      }

      stdout, stderr, status = Open3.capture3(env, script_path, chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("== Starting development server ==")
      expect(File.read(File.join(dir, "dev-args.log")).split).to eq(%w[--detach --restart-if-running])
    end
  end

  it "skips bin/dev when --skip-server is provided" do
    Dir.mktmpdir("setup-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      env = {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "WORKSPACE_ROOT" => File.join(dir, "workspace-root")
      }

      stdout, stderr, status = Open3.capture3(env, script_path, "--skip-server", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("== Setup complete! ==")
      expect(File.exist?(File.join(dir, "dev-args.log"))).to be(false)
    end
  end

  def prepare_script_fixture(dir)
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.mkdir_p(File.join(dir, "lib", "paid"))
    FileUtils.mkdir_p(File.join(dir, "stubbin"))
    FileUtils.mkdir_p(File.join(dir, "log", "dev-update"))
    FileUtils.mkdir_p(File.join(dir, "workspace-root"))

    script_path = File.join(dir, "bin", "setup")
    FileUtils.cp(script_source, script_path)
    FileUtils.chmod("+x", script_path)
    FileUtils.cp(log_truncator_source, File.join(dir, "lib", "paid", "log_truncator.rb"))

    write_executable(
      File.join(dir, "bin", "ensure-worktree-databases"),
      <<~BASH
        #!/usr/bin/env bash
        exit 0
      BASH
    )

    write_executable(
      File.join(dir, "bin", "dev"),
      <<~BASH
        #!/usr/bin/env bash
        printf '%s\n' "$@" > "#{dir}/dev-args.log"
        exit 0
      BASH
    )

    write_executable(
      File.join(dir, "bin", "yarn-postinstall"),
      <<~BASH
        #!/usr/bin/env bash
        exit 0
      BASH
    )

    write_executable(
      File.join(dir, "bin", "rails"),
      <<~BASH
        #!/usr/bin/env bash
        exit 0
      BASH
    )

    write_executable(
      File.join(dir, "stubbin", "git"),
      <<~BASH
        #!/usr/bin/env bash
        exit 0
      BASH
    )

    write_executable(
      File.join(dir, "stubbin", "bundle"),
      <<~BASH
        #!/usr/bin/env bash
        case "$1" in
          check)
            exit 0
            ;;
          install)
            exit 0
            ;;
          *)
            echo "unexpected bundle command: $*" >&2
            exit 1
            ;;
        esac
      BASH
    )

    write_executable(
      File.join(dir, "stubbin", "yarn"),
      <<~BASH
        #!/usr/bin/env bash
        exit 0
      BASH
    )

    write_executable(
      File.join(dir, "stubbin", "docker"),
      <<~BASH
        #!/usr/bin/env bash
        exit 0
      BASH
    )

    FileUtils.mkdir_p(File.join(dir, "scripts"))
    write_executable(
      File.join(dir, "scripts", "build-agent-image.sh"),
      <<~BASH
        #!/usr/bin/env bash
        exit 0
      BASH
    )

    script_path
  end

  def write_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod("+x", path)
  end
end
