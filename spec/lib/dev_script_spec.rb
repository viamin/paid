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

  # The diagnostic snapshot in dev_supervisor.sh normally calls
  # `pstree -aps $$`, which takes ~1.5s per invocation in this container and
  # dominates each bin/dev spec. These tests only care that snapshot files are
  # written with the expected labels, so opt into the lightweight `ps -ef` path.
  # The unhealthy-restart branch of bin/dev also waits 1s for overmind to
  # release its socket; shrink that grace period for tests. Open3.capture3
  # inherits the parent process env by default, so exporting here propagates
  # into each child bin/dev process.
  around do |example|
    prior = ENV.to_h.slice(
      "DEV_SUPERVISOR_FAST_DIAGNOSTICS",
      "DEV_SUPERVISOR_MONITOR_INTERVAL",
      "DEV_SUPERVISOR_QUIT_GRACE_SECONDS"
    )
    ENV["DEV_SUPERVISOR_FAST_DIAGNOSTICS"] = "1"
    ENV["DEV_SUPERVISOR_MONITOR_INTERVAL"] = "0.01"
    ENV["DEV_SUPERVISOR_QUIT_GRACE_SECONDS"] = "0"
    example.run
  ensure
    ENV["DEV_SUPERVISOR_FAST_DIAGNOSTICS"] = prior["DEV_SUPERVISOR_FAST_DIAGNOSTICS"]
    ENV["DEV_SUPERVISOR_MONITOR_INTERVAL"] = prior["DEV_SUPERVISOR_MONITOR_INTERVAL"]
    ENV["DEV_SUPERVISOR_QUIT_GRACE_SECONDS"] = prior["DEV_SUPERVISOR_QUIT_GRACE_SECONDS"]
  end

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
      script_path = prepare_script_fixture(dir, overmind: { running: true }, tmux: { pane_dead: false })

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

  it "restarts a healthy overmind session when requested" do
    Dir.mktmpdir("dev", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, overmind: { running: true }, tmux: { pane_dead: false })

      env = {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "SKIP_DEV_CLEANUP" => "1",
        "OVERMIND_SOCKET" => ".overmind.sock",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux")
      }
      stdout, stderr, status = Open3.capture3(env, script_path, "--restart-if-running", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("Overmind is already running and healthy. Restarting processes...")
      expect(stdout).to include("restarted web")
      expect(File.exist?(File.join(dir, "overmind-restart-ran"))).to be(true)
      expect(File.exist?(File.join(dir, "overmind-start-ran"))).to be(false)
      expect(File.exist?(File.join(dir, "overmind-quit-ran"))).to be(false)
    end
  end

  it "captures diagnostics when restarting a healthy overmind session fails" do
    Dir.mktmpdir("dev", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(
        dir,
        overmind: { running: true, restart_exit_status: 1 },
        tmux: { pane_dead: false }
      )

      env = {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "SKIP_DEV_CLEANUP" => "1",
        "OVERMIND_SOCKET" => ".overmind.sock",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux")
      }
      stdout, stderr, status = Open3.capture3(env, script_path, "--restart-if-running", chdir: dir)

      expect(status.success?).to be(false), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("Overmind is already running and healthy. Restarting processes...")
      expect(stderr).to include("Failed to restart healthy Overmind session. Capturing diagnostics...")
      expect(stderr).to include("restart failed")
      expect(Dir.glob(File.join(dir, "log", "dev-update", "diagnostics", "*bin-dev-healthy-overmind-restart-failed.log"))).not_to be_empty
    end
  end

  it "restarts an unhealthy overmind session with dead processes from overmind status" do
    Dir.mktmpdir("dev", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, overmind: { running: true, process_dead: true }, tmux: { pane_dead: false })

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

  it "waits for the overmind socket to appear before returning from --detach" do
    Dir.mktmpdir("dev", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, overmind: { create_socket_on_start: true })

      env = {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "SKIP_DEV_CLEANUP" => "1",
        "OVERMIND_SOCKET" => File.join(dir, ".overmind.sock"),
        "DEV_DETACH_READY_TIMEOUT" => "10"
      }
      stdout, stderr, status = Open3.capture3(env, script_path, "--detach", chdir: dir)
      wait_for_detached_child(dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("Detaching bin/dev")
      expect(stdout).to match(/bin\/dev detached \(setsid pid=\d+\)\. Use 'overmind connect' to attach\./)
      expect(stderr).not_to include("overmind socket did not appear")
      expect(File.socket?(File.join(dir, ".overmind.sock"))).to be(true)
    end
  end

  it "warns and exits when the overmind socket never appears after --detach" do
    Dir.mktmpdir("dev", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, overmind: { create_socket_on_start: false })

      env = {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "SKIP_DEV_CLEANUP" => "1",
        "OVERMIND_SOCKET" => File.join(dir, ".overmind.sock"),
        "DEV_DETACH_READY_TIMEOUT" => "0"
      }
      stdout, stderr, status = Open3.capture3(env, script_path, "--detach", chdir: dir)
      wait_for_detached_child(dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("Detaching bin/dev")
      expect(stderr).to include("overmind socket did not appear within 0s")
    end
  end

  it "captures an exit snapshot when overmind start fails" do
    Dir.mktmpdir("dev", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, overmind: { start_exit_status: 1 })

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

  def prepare_script_fixture(dir, overmind: {}, tmux: {})
    overmind_running = overmind.fetch(:running, false)
    overmind_process_dead = overmind.fetch(:process_dead, false)
    overmind_restart_exit_status = overmind.fetch(:restart_exit_status, 0)
    tmux_pane_dead = tmux.fetch(:pane_dead, false)
    start_exit_status = overmind.fetch(:start_exit_status, 0)
    create_socket_on_start = overmind.fetch(:create_socket_on_start, false)
    start_sleep = overmind.fetch(:start_sleep, 0)
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
            if [ "#{create_socket_on_start ? 1 : 0}" = "1" ] && [ -n "${OVERMIND_SOCKET:-}" ]; then
              ruby -rsocket -e 'path = ENV.fetch("OVERMIND_SOCKET"); File.unlink(path) if File.exist?(path); UNIXServer.open(path) { |s| s.close }'
            fi
            if [ "#{start_sleep}" -gt 0 ]; then
              sleep #{start_sleep}
            fi
            exit #{start_exit_status}
            ;;
          quit)
            touch "#{dir}/overmind-quit-ran"
            rm -f "#{dir}/overmind-running" "#{dir}/.overmind.sock"
            exit 0
            ;;
          restart)
            touch "#{dir}/overmind-restart-ran"
            if [ "#{overmind_restart_exit_status}" = "0" ]; then
              echo "restarted web"
            else
              echo "restart failed" >&2
            fi
            exit #{overmind_restart_exit_status}
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

  # Polls the overmind log for the "bin/dev exiting" marker written by the
  # EXIT trap in the detached child, so the tmpdir can be cleaned up safely.
  def wait_for_detached_child(dir, timeout: 15)
    log_path = File.join(dir, "log", "dev-update", "overmind.log")
    deadline = Time.now + timeout
    until Time.now > deadline
      return if File.exist?(log_path) && File.read(log_path).include?("bin/dev exiting")
      sleep 0.1
    end
  end

  def assert_before_start_snapshot(dir)
    diagnostics = Dir.glob(File.join(dir, "log", "dev-update", "diagnostics", "*bin-dev-before-start.log"))
    expect(diagnostics).not_to be_empty

    snapshot = File.read(diagnostics.first)
    expect(snapshot).to include("== shell context ==")
    expect(snapshot).not_to include("rg: not found")
  end
end
