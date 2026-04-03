# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "socket"
require "tmpdir"
require_relative "../support/exec_tmpdir"
require_relative "../support/overmind_env_helpers"

RSpec.describe "bin/dev" do # rubocop:disable RSpec/DescribeClass
  include ExecTmpdir
  include OvermindEnvHelpers
  let(:script_source) { File.expand_path("../../bin/dev", __dir__) }

  it "removes a stale Overmind socket before starting overmind" do
    Dir.mktmpdir("dev-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      socket_path = create_stale_socket(dir)

      env = {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "SKIP_DEV_CLEANUP" => "1",
        "OVERMIND_SOCKET" => ".overmind.sock"
      }
      stdout, stderr, status = Open3.capture3(env, script_path, chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("Removing stale Overmind socket...")
      expect(File.exist?(socket_path)).to be(false)
      expect(File.exist?(File.join(dir, "overmind-start-ran"))).to be(true)
    end
  end

  it "removes stale tmux sockets and writes diagnostics logs" do
    Dir.mktmpdir("dev-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      tmux_socket_dir = File.join(dir, "tmux")
      FileUtils.mkdir_p(tmux_socket_dir)
      stale_tmux_socket = create_socket(File.join(tmux_socket_dir, "overmind-#{File.basename(dir)}-stale"))

      env = {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "SKIP_DEV_CLEANUP" => "1",
        "OVERMIND_SOCKET" => ".overmind.sock",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => tmux_socket_dir
      }
      stdout, stderr, status = Open3.capture3(env, script_path, chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(stale_tmux_socket)).to be(false)
      expect(File.exist?(File.join(dir, "log", "dev-update", "tmux.log"))).to be(true)
      assert_before_start_snapshot(dir)
    end
  end

  it "starts overmind successfully even when bundler env is present" do
    Dir.mktmpdir("dev-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      env = bundler_contaminated_env(dir).merge("SKIP_DEV_CLEANUP" => "1")
      stdout, stderr, status = Open3.capture3(env, script_path, chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(File.join(dir, "overmind-start-ran"))).to be(true)
      log = overmind_invocation_log(dir)
      expect(log).to include("CMD=start")
      start_block = log.split("\n--\n").find { |block| block.lines.first&.start_with?("CMD=start") }
      expect(start_block).not_to include("BUNDLE_GEMFILE=")
      expect(start_block).not_to include("RUBYOPT=")
    end
  end

  it "exits cleanly when overmind is already running and healthy" do
    Dir.mktmpdir("dev", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, overmind_running: true, tmux_pane_dead: false)

      env = {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "SKIP_DEV_CLEANUP" => "1",
        "OVERMIND_SOCKET" => ".overmind.sock",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux")
      }
      stdout, stderr, status = Open3.capture3(env, script_path, chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("Overmind is already running and healthy.")
      expect(stdout).to include("web       12345     running")
      expect(File.exist?(File.join(dir, "overmind-start-ran"))).to be(false)
      expect(File.exist?(File.join(dir, "overmind-quit-ran"))).to be(false)
    end
  end

  it "restarts an unhealthy overmind session with dead processes from overmind status" do
    Dir.mktmpdir("dev", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, overmind_running: true, overmind_process_dead: true, tmux_pane_dead: false)

      env = {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "SKIP_DEV_CLEANUP" => "1",
        "OVERMIND_SOCKET" => ".overmind.sock",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux")
      }
      stdout, stderr, status = Open3.capture3(env, script_path, chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("Detected unhealthy Overmind session with dead processes. Restarting it...")
      expect(File.exist?(File.join(dir, "overmind-quit-ran"))).to be(true)
      expect(File.exist?(File.join(dir, "overmind-start-ran"))).to be(true)
      expect(Dir.glob(File.join(dir, "log", "dev-update", "diagnostics", "*bin-dev-unhealthy-overmind.log"))).not_to be_empty
    end
  end

  it "captures an exit snapshot when overmind start fails" do
    Dir.mktmpdir("dev", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, start_exit_status: 1)

      env = {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "SKIP_DEV_CLEANUP" => "1",
        "OVERMIND_SOCKET" => ".overmind.sock"
      }
      stdout, stderr, status = Open3.capture3(env, script_path, chdir: dir)

      expect(status.success?).to be(false), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(Dir.glob(File.join(dir, "log", "dev-update", "diagnostics", "*bin-dev-overmind-start-failed.log"))).not_to be_empty
      expect(Dir.glob(File.join(dir, "log", "dev-update", "diagnostics", "*bin-dev-exit-1.log"))).not_to be_empty
    end
  end

  def write_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod("+x", path)
  end

  def prepare_script_fixture(dir, overmind_running: false, overmind_process_dead: false, tmux_pane_dead: false, start_exit_status: 0)
    FileUtils.mkdir_p(File.join(dir, "stubbin"))
    FileUtils.mkdir_p(File.join(dir, "bin", "lib"))
    FileUtils.mkdir_p(File.join(dir, "config"))
    FileUtils.mkdir_p(File.join(dir, "tmux"))

    script_path = File.join(dir, "bin", "dev")
    FileUtils.cp(script_source, script_path)
    FileUtils.chmod("+x", script_path)
    FileUtils.cp(File.expand_path("../../bin/lib/dev_supervisor.sh", __dir__), File.join(dir, "bin", "lib", "dev_supervisor.sh"))
    FileUtils.cp(File.expand_path("../../config/overmind.tmux.conf", __dir__), File.join(dir, "config", "overmind.tmux.conf"))

    FileUtils.touch(File.join(dir, "overmind-running")) if overmind_running
    create_socket(File.join(dir, ".overmind.sock")) if overmind_running
    create_socket(File.join(dir, "tmux", "overmind-#{File.basename(dir)}-active")) if overmind_running

    write_executable(
      File.join(dir, "stubbin", "overmind"),
      <<~BASH
        #!/usr/bin/env bash
        {
          printf 'CMD=%s\n' "$1"
          env | sort | grep -E '^(BUNDLE_GEMFILE|BUNDLE_BIN_PATH|BUNDLER_SETUP|BUNDLER_VERSION|RUBYLIB|RUBYOPT|RUBYGEMS_GEMDEPS)=' || true
          printf '%s\n' '--'
        } >> "#{dir}/stubbin/overmind-env.log"
        case "$1" in
          status)
            if [ -e "#{dir}/overmind-running" ]; then
              echo "PROCESS   PID       STATUS"
              if [ "#{overmind_process_dead ? 1 : 0}" = "1" ]; then
                echo "web       12345     dead"
              else
                echo "web       12345     running"
              fi
              exit 0
            fi
            exit 1
            ;;
          start)
            touch "#{dir}/overmind-start-ran"
            touch "#{dir}/overmind-running"
            exit #{start_exit_status}
            ;;
          quit)
            touch "#{dir}/overmind-quit-ran"
            rm -f "#{dir}/overmind-running" "#{dir}/.overmind.sock"
            exit 0
            ;;
          *)
            echo "unexpected overmind command: $*" >&2
            exit 1
            ;;
        esac
      BASH
    )

    write_executable(
      File.join(dir, "stubbin", "tmux"),
      <<~BASH
        #!/usr/bin/env bash
        if [ "$1" = "-S" ] && [ "$3" = "ls" ]; then
          if [ -e "#{dir}/overmind-running" ]; then
            exit 0
          fi
          exit 1
        fi

        if [ "$1" = "-S" ] && [ "$3" = "list-panes" ]; then
          if [ "#{tmux_pane_dead ? 1 : 0}" = "1" ]; then
            echo "1 paid:web.0 ruby"
          else
            echo "0 paid:web.0 ruby"
          fi
          exit 0
        fi
        echo "unexpected tmux command: $*" >&2
        exit 1
      BASH
    )

    script_path
  end

  def create_stale_socket(dir)
    socket_path = File.join(dir, ".overmind.sock")
    create_socket(socket_path)
  end

  def create_socket(path)
    UNIXServer.open(path) { |server| server.close }
    expect(File.socket?(path)).to be(true)
    path
  end

  def assert_before_start_snapshot(dir)
    diagnostics = Dir.glob(File.join(dir, "log", "dev-update", "diagnostics", "*bin-dev-before-start.log"))
    expect(diagnostics).not_to be_empty

    snapshot = File.read(diagnostics.first)
    expect(snapshot).to include("== shell context ==")
    expect(snapshot).not_to include("rg: not found")
  end
end
