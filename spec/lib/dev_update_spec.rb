# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "socket"
require "tmpdir"
require "timeout"
require_relative "../support/exec_tmpdir"

RSpec.describe "bin/dev-update" do # rubocop:disable RSpec/DescribeClass
  include ExecTmpdir
  let(:script_source) { File.expand_path("../../bin/dev-update", __dir__) }

  it "removes a stale Overmind socket before restarting the dev environment" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      socket_path = create_stale_socket(dir)

      env = { "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}" }
      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(socket_path)).to be(false)
      expect(File.exist?(File.join(dir, "overmind-quit-ran"))).to be(false)
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(true)
      expect(stdout).to include("Overmind is healthy after restart.")
      expect(stdout).to include("Streaming detached bin/dev output to log/dev_start.log")
      expect(File.read(File.join(dir, "log", "dev_start.log"))).to include("bin/dev booted")

      Timeout.timeout(5) do
        sleep 0.1 until File.exist?(File.join(dir, "dev-ran"))
      end
    end
  end

  it "tries to recover the dev environment when setup fails after stopping Overmind" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, setup_exit_status: 1, start_overmind_running: true)
      create_stale_socket(dir)

      env = { "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}" }
      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(false), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(File.join(dir, "overmind-quit-ran"))).to be(true)
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(true)
      expect(stdout).to include("Setup failed after Overmind stop.")
      expect(stdout).to include("Attempting recovery start because Overmind was stopped during this update.")
      expect(stdout).to include("Recovery start succeeded.")
      expect(stdout).to include("ERROR: Full restart aborted because bin/setup --skip-server failed.")
    end
  end

  it "fails loudly when restart does not restore a healthy Overmind session" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, dev_starts_overmind: false)

      env = { "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}" }
      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(false), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(true)
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(true)
      expect(stdout).to include("Inspect log/dev_start.log for detached bin/dev output.")
      expect(stdout).to include("ERROR: Full restart completed setup but failed to restore a healthy Overmind session.")
    end
  end

  def write_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod("+x", path)
  end

  def prepare_script_fixture(dir, setup_exit_status: 0, start_overmind_running: false, dev_starts_overmind: true)
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.mkdir_p(File.join(dir, "log"))
    FileUtils.mkdir_p(File.join(dir, "stubbin"))

    FileUtils.touch(File.join(dir, "overmind-running")) if start_overmind_running

    script_path = File.join(dir, "bin", "dev-update")
    FileUtils.cp(script_source, script_path)
    FileUtils.chmod("+x", script_path)

    dev_start_line = dev_starts_overmind ? %(touch "#{dir}/overmind-running") : ""

    write_executable(
      File.join(dir, "bin", "setup"),
      <<~BASH
        #!/usr/bin/env bash
        touch "#{dir}/setup-ran"
        exit #{setup_exit_status}
      BASH
    )

    write_executable(
      File.join(dir, "bin", "dev"),
      <<~BASH
        #!/usr/bin/env bash
        touch "#{dir}/dev-ran"
        #{dev_start_line}
        echo "bin/dev booted"
      BASH
    )

    write_executable(
      File.join(dir, "stubbin", "git"),
      <<~BASH
        #!/usr/bin/env bash
        case "$1" in
          rev-parse)
            echo "main"
            ;;
          pull)
            exit 0
            ;;
          *)
            echo "unexpected git command: $*" >&2
            exit 1
            ;;
        esac
      BASH
    )

    write_executable(
      File.join(dir, "stubbin", "overmind"),
      <<~BASH
        #!/usr/bin/env bash
        case "$1" in
          status)
            [ -e "#{dir}/overmind-running" ]
            exit $?
            ;;
          quit)
            touch "#{dir}/overmind-quit-ran"
            rm -f "#{dir}/overmind-running"
            exit 0
            ;;
          *)
            echo "unexpected overmind command: $*" >&2
            exit 1
            ;;
        esac
      BASH
    )

    script_path
  end

  def create_stale_socket(dir)
    socket_path = File.join(dir, ".overmind.sock")
    UNIXServer.open(socket_path) { |server| server.close }
    expect(File.socket?(socket_path)).to be(true)
    socket_path
  end
end
