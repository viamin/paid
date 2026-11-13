# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "socket"
require "tmpdir"
require "timeout"
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
      File.utime(Time.now - 120, Time.now - 120, stale_tmux_socket)

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

  it "removes a tmux socket whose server has no sessions before starting" do # @spec RAILS-CONTROL-PLANE-016
    Dir.mktmpdir("dev-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, tmux: { empty_session_socket: true })
      empty_socket = File.join(dir, "tmux", "overmind-#{File.basename(dir)}-empty")
      File.utime(Time.now - 120, Time.now - 120, empty_socket)
      env = {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "SKIP_DEV_CLEANUP" => "1",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux")
      }

      _stdout, stderr, status = Open3.capture3(env, script_path, chdir: dir)

      expect(status.success?).to be(true), stderr
      expect(File.exist?(empty_socket)).to be(false)
      expect(File.exist?(File.join(dir, "empty-tmux-server-stopped"))).to be(true)
    end
  end

  it "does not detach a newly created tmux server before its first session exists" do # @spec RAILS-CONTROL-PLANE-016
    Dir.mktmpdir("dev-script-spec", exec_tmpdir) do |dir|
      prepare_script_fixture(dir, tmux: { empty_session_socket: true })
      empty_socket = File.join(dir, "tmux", "overmind-#{File.basename(dir)}-empty")
      env = {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux")
      }

      _stdout, stderr, status = Open3.capture3(env, "bash", "-c",
        "APP_ROOT=\"$PWD\"; source bin/lib/dev_supervisor.sh; dev_supervisor_cleanup_stale_tmux_sockets", chdir: dir)

      expect(status.success?).to be(true), stderr
      expect(File.socket?(empty_socket)).to be(true)
      expect(File.exist?(File.join(dir, "empty-tmux-server-stopped"))).to be(false)
    end
  end

  it "refuses a concurrent same-workspace start while cleaning empty tmux servers" do # @spec RAILS-CONTROL-PLANE-016, RAILS-CONTROL-PLANE-017
    Dir.mktmpdir("dev-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(
        dir,
        overmind: { active_tmux_socket_on_start: true, start_sleep: 1 },
        tmux: { empty_session_socket: true }
      )
      empty_socket = File.join(dir, "tmux", "overmind-#{File.basename(dir)}-empty")
      File.utime(Time.now - 120, Time.now - 120, empty_socket)
      env = dev_script_env(dir)
      first, ready_reader = start_dev_with_ready_pipe(env, script_path, dir)
      expect(ready_reader.read(1)).to eq("1")
      second_stdout, second_stderr, second_status = run_dev_within(0.5, env, script_path, dir)
      Process.wait(first)
      ready_reader.close
      expect(second_status.success?).to be(false), -> { "stdout: #{second_stdout}\nstderr: #{second_stderr}" }
      expect(second_stderr).to include("another bin/dev is cleaning up or starting Overmind")
      expect(File.read(File.join(dir, "overmind-start-count")).lines.count).to eq(1)
    end
  end

  it "refuses a duplicate start when the Overmind control socket is gone but panes remain live" do # @spec RAILS-CONTROL-PLANE-017
    Dir.mktmpdir("dev-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, tmux: { orphan_live_session: true })
      env = {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "SKIP_DEV_CLEANUP" => "1",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux")
      }

      _stdout, stderr, status = Open3.capture3(env, script_path, chdir: dir)

      expect(status.success?).to be(false)
      expect(stderr).to include("existing or starting Overmind tmux session")
      expect(File.exist?(File.join(dir, "overmind-start-ran"))).to be(false)
    end
  end

  it "allows startup when only another worktree has a live tmux session" do # @spec RAILS-CONTROL-PLANE-017
    Dir.mktmpdir("dev-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, tmux: { other_worktree_session: true })
      env = {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "SKIP_DEV_CLEANUP" => "1",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux")
      }

      _stdout, stderr, status = Open3.capture3(env, script_path, chdir: dir)

      expect(status.success?).to be(true), stderr
      expect(File.exist?(File.join(dir, "overmind-start-ran"))).to be(true)
    end
  end

  it "keeps a healthy Overmind session running when an old tmux socket has no sessions" do # @spec RAILS-CONTROL-PLANE-016
    Dir.mktmpdir("dev-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, overmind: { running: true }, tmux: { empty_session_socket: true })
      env = {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "SKIP_DEV_CLEANUP" => "1",
        "OVERMIND_SOCKET" => ".overmind.sock",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux")
      }

      stdout, stderr, status = Open3.capture3(env, script_path, chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("Overmind is already running and healthy.")
      expect(File.exist?(File.join(dir, "overmind-quit-ran"))).to be(false)
    end
  end

  it "still restarts an Overmind session with a dead pane" do # @spec RAILS-CONTROL-PLANE-016
    Dir.mktmpdir("dev-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, overmind: { running: true }, tmux: { pane_dead: true })
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

  it "keeps GoodJob in the web process without enabling unconditional Overmind restarts" do # @spec RAILS-CONTROL-PLANE-014
    Dir.mktmpdir("dev-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      env = { "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}", "SKIP_DEV_CLEANUP" => "1" }
      _stdout, stderr, status = Open3.capture3(env, script_path, chdir: dir)

      expect(status.success?).to be(true), stderr
      expect(overmind_invocation_log(dir)).to include("ARGS=start -f Procfile.dev -F config/overmind.tmux.conf")
      expect(overmind_invocation_log(dir)).not_to include("--auto-restart")
      procfile = File.read(File.expand_path("../../Procfile.dev", __dir__))
      expect(procfile).to include("web: bin/dev-web")
      expect(procfile).not_to include("jobs:")
    end
  end

  it "stops after repeated exit 137" do # @spec RAILS-CONTROL-PLANE-014
    with_dev_web do |dir|
      write_executable(File.join(dir, "bin", "rails"), <<~BASH)
        #!/usr/bin/env bash
        count=$(cat count 2>/dev/null || echo 0)
        count=$((count + 1))
        echo "$count" > count
        exit 137
      BASH
      _stdout, stderr, status = run_dev_web(dir)
      expect(status.exitstatus).to eq(137)
      expect(File.read(File.join(dir, "count"))).to eq("4\n")
      expect(stderr).to include("stopping automatic recovery")
    end
  end

  it "passes through a nonrecoverable web exit" do # @spec RAILS-CONTROL-PLANE-014
    with_dev_web do |dir|
      write_executable(File.join(dir, "bin", "rails"), <<~BASH)
        #!/usr/bin/env bash
        echo run >> count
        exit 1
      BASH
      _stdout, _stderr, status = run_dev_web(dir)
      expect(status.exitstatus).to eq(1)
      expect(File.readlines(File.join(dir, "count"))).to eq([ "run\n" ])
    end
  end

  it "recovers from an isolated exit 137" do # @spec RAILS-CONTROL-PLANE-014
    with_dev_web do |dir|
      write_executable(File.join(dir, "bin", "rails"), <<~BASH)
        #!/usr/bin/env bash
        count=$(cat count 2>/dev/null || echo 0)
        count=$((count + 1))
        echo "$count" > count
        if [ "$count" -eq 1 ]; then exit 137; fi
        exit 0
      BASH
      _stdout, _stderr, status = run_dev_web(dir)
      expect(status.exitstatus).to eq(0)
      expect(File.read(File.join(dir, "count"))).to eq("2\n")
    end
  end

  it "stops the web child on TERM" do # @spec RAILS-CONTROL-PLANE-014
    assert_web_stops_on("TERM")
  end

  it "stops the web child on INT" do # @spec RAILS-CONTROL-PLANE-014
    assert_web_stops_on("INT")
  end

  def assert_web_stops_on(signal)
    with_dev_web do |dir|
      write_executable(File.join(dir, "bin", "rails"), <<~BASH)
        #!/usr/bin/env bash
        echo "$$"
        exec sleep 30
      BASH
      Open3.popen3(File.join(dir, "bin", "dev-web"), chdir: dir) do |stdin, stdout, _stderr, waiter|
        Timeout.timeout(5) do
          child_pid = Integer(stdout.gets)
          Process.kill(signal, waiter.pid)
          expect(waiter.value.exitstatus).to eq(0)
          expect { Process.kill(0, child_pid) }.to raise_error(Errno::ESRCH)
        end
      ensure
        stdin.close unless stdin.closed?
        Process.kill("KILL", waiter.pid) if waiter.alive?
      end
    end
  end

  it "samples memory in the existing supervisor" do # @spec RAILS-CONTROL-PLANE-015
    Dir.mktmpdir("dev-script-spec", exec_tmpdir) do |dir|
      prepare_script_fixture(dir)
      FileUtils.mkdir_p(File.join(dir, "log", "dev-update"))
      write_executable(File.join(dir, "stubbin", "ps"), <<~BASH)
        #!/usr/bin/env bash
        cat <<'OUTPUT'
        ruby 100 puma 8.0.2 (tcp://0.0.0.0:3000) [paid]
        ruby 200 ruby bin/temporal_worker
        ruby 300 ruby bin/temporal_worker
        ruby 400 unrelated ruby process
        OUTPUT
      BASH

      _stdout, stderr, status = Open3.capture3({ "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}" }, "bash", "-c",
        "source bin/lib/dev_supervisor.sh; dev_supervisor_log_memory_sample", chdir: dir)

      expect(status.success?).to be(true), stderr
      sample = File.read(File.join(dir, "log", "dev-update", "overmind.log"))
      expect(sample).to match(/memory_sample puma_rss_kb=100 temporal_rss_kb=500 host_available_kb=(?:\d+|unknown) cgroup_current_bytes=(?:\d+|unknown) cgroup_max_bytes=(?:\d+|unknown|max) cgroup_oom_kills=(?:\d+|unknown)/)
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

  def with_dev_web
    Dir.mktmpdir("dev-web-spec", exec_tmpdir) do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      FileUtils.cp(File.expand_path("../../bin/dev-web", __dir__), File.join(dir, "bin", "dev-web"))
      yield dir
    end
  end

  def run_dev_web(dir)
    Open3.capture3({ "PAID_WEB_RESTART_DELAY_SECONDS" => "0" }, File.join(dir, "bin", "dev-web"), chdir: dir)
  end

  def prepare_script_fixture(dir, overmind: {}, tmux: {})
    overmind_running = overmind.fetch(:running, false)
    overmind_process_dead = overmind.fetch(:process_dead, false)
    overmind_restart_exit_status = overmind.fetch(:restart_exit_status, 0)
    tmux_pane_dead = tmux.fetch(:pane_dead, false)
    empty_session_socket = tmux.fetch(:empty_session_socket, false)
    orphan_live_session = tmux.fetch(:orphan_live_session, false)
    other_worktree_session = tmux.fetch(:other_worktree_session, false)
    start_exit_status = overmind.fetch(:start_exit_status, 0)
    create_socket_on_start = overmind.fetch(:create_socket_on_start, false)
    active_tmux_socket_on_start = overmind.fetch(:active_tmux_socket_on_start, false)
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
    create_socket(File.join(dir, "tmux", "overmind-#{File.basename(dir)}-empty")) if empty_session_socket
    create_socket(File.join(dir, "tmux", "overmind-#{File.basename(dir)}-orphan")) if orphan_live_session
    create_socket(File.join(dir, "tmux", "overmind-#{File.basename(dir)}-other")) if other_worktree_session

    write_executable(
      File.join(dir, "stubbin", "overmind"),
      <<~BASH
        #!/usr/bin/env bash
        {
          printf 'CMD=%s\n' "$1"
          printf 'ARGS=%s\n' "$*"
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
            echo start >> "#{dir}/overmind-start-count"
            touch "#{dir}/overmind-running"
            if [ "#{active_tmux_socket_on_start ? 1 : 0}" = "1" ]; then
              ruby -rsocket -e 'path = ARGV.fetch(0); File.unlink(path) if File.exist?(path); UNIXServer.open(path) { |s| s.close }' "#{dir}/tmux/overmind-#{File.basename(dir)}-active"
            fi
            if [ -n "${DEV_SCRIPT_READY_FD:-}" ]; then
              printf 1 >&"$DEV_SCRIPT_READY_FD"
            fi
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
            rm -f "#{dir}/overmind-running" "#{dir}/.overmind.sock" "#{dir}/tmux/overmind-#{File.basename(dir)}-active"
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
        if [ "$1" = "-S" ] && [[ "$2" == *-empty ]]; then
          if [ "$3" = "ls" ]; then exit 0; fi
          if [ "$3" = "list-panes" ]; then echo "no current target" >&2; exit 1; fi
          if [ "$3" = "kill-server" ]; then touch "#{dir}/empty-tmux-server-stopped"; rm -f "$2"; exit 0; fi
        fi
        if [ "$1" = "-S" ] && [[ "$2" == *-orphan ]]; then
          if [ "$3" = "ls" ]; then echo "paid: 1 windows"; exit 0; fi
          if [ "$3" = "list-panes" ]; then
            if [[ "$6" == *pane_current_path* ]]; then echo "$PWD"; else echo "0 paid:web.0 ruby"; fi
            exit 0
          fi
        fi
        if [ "$1" = "-S" ] && [[ "$2" == *-other ]]; then
          if [ "$3" = "ls" ]; then echo "paid: 1 windows"; exit 0; fi
          if [ "$3" = "list-panes" ]; then echo "/other/worktree"; exit 0; fi
        fi
        if [ "$1" = "-S" ] && [ "$3" = "ls" ]; then
          if [ -e "#{dir}/overmind-running" ]; then
            echo "paid: 1 windows"
            exit 0
          fi
          exit 1
        fi

        if [ "$1" = "-S" ] && [ "$3" = "list-panes" ]; then
          if [[ "$6" == *pane_current_path* ]]; then
            echo "$PWD"
            exit 0
          fi
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

  def dev_script_env(dir)
    {
      "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
      "SKIP_DEV_CLEANUP" => "1",
      "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux")
    }
  end

  def start_dev_with_ready_pipe(env, script_path, dir)
    ready_reader, ready_writer = IO.pipe
    pid = Process.spawn(
      env.merge("DEV_SCRIPT_READY_FD" => ready_writer.fileno.to_s),
      script_path,
      chdir: dir,
      ready_writer.fileno => ready_writer
    )
    ready_writer.close
    [ pid, ready_reader ]
  end

  def run_dev_within(timeout, env, script_path, dir)
    Open3.popen3(env, script_path, chdir: dir) do |stdin, stdout, stderr, waiter|
      stdin.close
      status = Timeout.timeout(timeout) { waiter.value }
      [ stdout.read, stderr.read, status ]
    ensure
      Process.kill("TERM", waiter.pid) if waiter&.alive?
      waiter&.value
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
