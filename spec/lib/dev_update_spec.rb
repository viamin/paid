# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "socket"
require "tmpdir"
require "timeout"
require_relative "../support/exec_tmpdir"
require_relative "../support/overmind_env_helpers"

RSpec.describe "bin/dev-update" do # rubocop:disable RSpec/DescribeClass
  include ExecTmpdir
  include OvermindEnvHelpers
  let(:script_source) { File.expand_path("../../bin/dev-update", __dir__) }
  let(:poll_env) do
    {
      "DEV_UPDATE_OVERMIND_STOP_POLL_COUNT" => "3",
      # start_dev launches `nohup bin/dev` asynchronously before polling for
      # health, so the start window must tolerate the detached stub being
      # scheduled late: under CI load the stub has needed hundreds of
      # milliseconds before `overmind status` first succeeds, while
      # 3 x 0.01s gives it only tens. ~2s of polling keeps recovery tests
      # deterministic without slowing the unhealthy-path tests meaningfully.
      "DEV_UPDATE_OVERMIND_START_POLL_COUNT" => "100",
      "DEV_UPDATE_OVERMIND_POLL_INTERVAL" => "0.02",
      # Require only 1 consecutive healthy poll (instead of the default 2) so
      # tests are resilient to CI timing variance when nohup bin/dev starts up
      # asynchronously and may not be visible on the very first poll.
      "DEV_UPDATE_OVERMIND_HEALTHY_CONFIRM_COUNT" => "1",
      # Worker adoption verification polls the readiness flag files; the stub
      # workers write them immediately, and stale-revision tests rely on the
      # bounded budget expiring quickly (~0.5s).
      "DEV_UPDATE_WORKER_ADOPTION_POLL_COUNT" => "25",
      "DEV_UPDATE_WORKER_DRAIN_POLL_COUNT" => "25"
    }
  end

  # Skip the slow pstree call inside dev_supervisor.sh's diagnostic snapshots.
  # See spec/lib/dev_script_spec.rb for rationale.
  around do |example|
    previous = ENV["DEV_SUPERVISOR_FAST_DIAGNOSTICS"]
    ENV["DEV_SUPERVISOR_FAST_DIAGNOSTICS"] = "1"
    # Isolate the worker readiness flag directory (TMPDIR) per example so the
    # stub workers' flag files cannot leak across examples or into the host's
    # real /tmp. bin/dev-update and the stubs both resolve the flag directory
    # from TMPDIR, mirroring Ruby's Dir.tmpdir.
    Dir.mktmpdir("dev-update-readiness", nil) do |readiness_dir|
      previous_tmpdir = ENV["TMPDIR"]
      ENV["TMPDIR"] = readiness_dir
      example.run
    ensure
      ENV["TMPDIR"] = previous_tmpdir
    end
  ensure
    ENV["DEV_SUPERVISOR_FAST_DIAGNOSTICS"] = previous
  end

  # @spec POSTGRESQL-PERSISTENCE-011
  it "disables automatic schema dumps for setup and migration subprocesses" do
    [ false, true ].each do |migration_trigger|
      Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
        script_path = prepare_script_fixture(dir)
        %w[poll agent].each { |mode| FileUtils.rm_f(worker_readiness_path(mode)) }
        env = migration_trigger_env(dir)
        env.delete("DEV_UPDATE_CHANGED_FILES") unless migration_trigger
        env.delete("DEV_UPDATE_RESTART_TRIGGER_FILES") unless migration_trigger

        _stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

        expect(status.success?).to be(true), stderr
        expect(File.read(File.join(dir, "setup-schema-env.log")).strip).to eq("1")
        if migration_trigger
          expect(File.read(File.join(dir, "migrate-schema-env.log")).strip).to eq("1")
        end
      end
    end
  end

  # @spec PROMPT-DEFAULT-SYNC-007
  it "synchronizes prompt defaults before completing a lightweight update" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      env = poll_env.merge("PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}", "OVERMIND_SOCKET" => ".overmind.sock")

      _stdout, stderr, status = Open3.capture3(env, script_path, "--lightweight", chdir: dir)

      expect(status.success?).to be(true), stderr
      expect(File.read(File.join(dir, "calls.log"))).to include("rails prompts:sync_defaults\n")
      expect(read_updater_log(dir)).to match(/Prompt defaults synchronized.*Lightweight update complete/m)
    end
  end

  # @spec PROMPT-DEFAULT-SYNC-007
  it "fails a development update when prompt synchronization fails" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, rails_sync_exit_status: 1)
      env = poll_env.merge("PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}", "OVERMIND_SOCKET" => ".overmind.sock")

      _stdout, _stderr, status = Open3.capture3(env, script_path, "--lightweight", chdir: dir)

      expect(status.success?).to be(false)
      expect(read_updater_log(dir)).to include("ERROR: bin/rails prompts:sync_defaults failed")
    end
  end

  # @spec PROMPT-DEFAULT-SYNC-007
  it "recovers a stopped environment when prompt synchronization fails during a full update" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, start_overmind_running: true, rails_sync_exit_status: 1)
      create_stale_socket(dir)
      env = poll_env.merge("PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}", "OVERMIND_SOCKET" => ".overmind.sock")

      _stdout, _stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(false)
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(true), -> { read_updater_log(dir) }
      expect(read_updater_log(dir)).to include("Attempting recovery start because Overmind was stopped during this update.")
      expect(read_updater_log(dir)).to include("Recovery start succeeded.")
    end
  end

  # @spec PROMPT-DEFAULT-SYNC-007
  it "recovers a stopped environment when an upgraded lightweight update cannot synchronize prompts" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(
        dir,
        start_overmind_running: true,
        pull_diff_files: %w[config/initializers/temporal.rb],
        rails_sync_exit_status: 1
      )
      create_stale_socket(dir)
      env = poll_env.merge("PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}", "OVERMIND_SOCKET" => ".overmind.sock")

      _stdout, _stderr, status = Open3.capture3(env, script_path, "--lightweight", chdir: dir)

      expect(status.success?).to be(false)
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(true), -> { read_updater_log(dir) }
      expect(read_updater_log(dir)).to include("Recovery start succeeded.")
    end
  end

  it "removes a stale Overmind socket before restarting the dev environment" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      socket_path = create_stale_socket(dir)

      env = poll_env.merge("PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}", "OVERMIND_SOCKET" => ".overmind.sock")
      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)
      updater_log = read_updater_log(dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(socket_path)).to be(false)
      expect(File.exist?(File.join(dir, "overmind-quit-ran"))).to be(false)
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(true)
      expect(updater_log).to include("Overmind is healthy after restart.")
      expect(updater_log).to include("Streaming detached bin/dev output to log/dev-update/dev-start.log")
      expect(wait_for_dev_start_log(dir)).to include("bin/dev booted")

      Timeout.timeout(5) do
        sleep 0.1 until File.exist?(File.join(dir, "dev-ran"))
      end
    end
  end

  it "defers worker adoption instead of killing a same-workspace orphaned tmux session when the control socket is missing" do # @spec TEMPORAL-ORCHESTRATION-019
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      # A missing control socket cannot be quit gracefully, so stop_overmind
      # would force-kill the orphaned session, interrupting any worker_poll/
      # worker_agent Temporal workers it still hosts without a quiescence
      # acknowledgement. The updater must defer before stopping Overmind.
      script_path = prepare_script_fixture(dir, tmux: :same_workspace)
      create_overmind_tmux_socket(dir)
      env = poll_env.merge(
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux")
      )

      _stdout, _stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(false)
      expect(File.exist?(File.join(dir, "tmux-session-stopped"))).to be(false)
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(false)
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(false)
      calls_log = File.join(dir, "calls.log")
      expect(File.exist?(calls_log) ? File.read(calls_log) : "").not_to include("tmux kill-session")
      expect(read_updater_log(dir)).to include("deferring worker adoption before stopping Overmind")
      expect(read_updater_log(dir)).to include("orphaned Overmind tmux session")
    end
  end

  it "stops a worker-free same-workspace orphaned tmux session before setup when the control socket is missing" do # @spec RAILS-CONTROL-PLANE-019
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      # The orphaned session hosts no worker_poll/worker_agent window, so the
      # worker-quiescence gate verifies no Temporal worker will be stopped and
      # the session is cleaned up before setup as RAILS-CONTROL-PLANE-019 requires.
      script_path = prepare_script_fixture(dir, tmux: :same_workspace_worker_free)
      create_overmind_tmux_socket(dir)
      env = poll_env.merge(
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux")
      )

      _stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(true), stderr
      expect(File.exist?(File.join(dir, "tmux-session-stopped"))).to be(true)
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(true)
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(true)
      expect(File.readlines(File.join(dir, "calls.log"))).to include("tmux kill-session paid\n")
      expect(read_updater_log(dir)).to include("Stopped orphaned Overmind tmux session")
    end
  end

  it "does not stop an orphaned tmux session rooted in another worktree" do # @spec RAILS-CONTROL-PLANE-019
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, tmux: :other_worktree)
      create_overmind_tmux_socket(dir)
      env = poll_env.merge(
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux")
      )

      _stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(true), stderr
      expect(File.exist?(File.join(dir, "tmux-session-stopped"))).to be(false)
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(true)
    end
  end

  it "does not invoke tmux cleanup when no Overmind session exists" do # @spec RAILS-CONTROL-PLANE-019
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, tmux: :same_workspace)
      env = poll_env.merge(
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux")
      )

      _stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(true), stderr
      expect(File.exist?(File.join(dir, "tmux-session-stopped"))).to be(false)
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(true)
    end
  end

  it "fails before setup with session identity when an orphaned tmux session cannot be stopped" do # @spec RAILS-CONTROL-PLANE-019
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, tmux: :stop_fails)
      socket = create_overmind_tmux_socket(dir)
      env = poll_env.merge(
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux")
      )

      _stdout, _stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(false)
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(false)
      expect(read_updater_log(dir)).to include("Cannot safely stop orphaned Overmind tmux session (#{socket}|paid)")
      expect(Dir.glob(File.join(dir, "log", "dev-update", "diagnostics", "*dev-update-orphaned-tmux-stop-failed.log"))).not_to be_empty
    end
  end

  it "continues setup and startup when an orphaned socket has no tmux server" do # @spec RAILS-CONTROL-PLANE-019
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, tmux: :no_server)
      create_overmind_tmux_socket(dir)
      env = poll_env.merge(
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux")
      )

      _stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(true), stderr
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(true)
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(true)
      expect(File.read(File.join(dir, "calls.log"))).not_to include("tmux kill-session")
    end
  end

  it "fails before setup when an orphaned tmux session cannot be inspected" do # @spec RAILS-CONTROL-PLANE-019
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, tmux: :inspection_fails)
      socket = create_overmind_tmux_socket(dir)
      env = poll_env.merge(
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux")
      )

      _stdout, _stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(false)
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(false)
      expect(File.read(File.join(dir, "calls.log"))).not_to include("tmux kill-session")
      expect(read_updater_log(dir)).to include("Cannot safely stop orphaned Overmind tmux session (#{socket}|<uninspectable>)")
      expect(Dir.glob(File.join(dir, "log", "dev-update", "diagnostics", "*dev-update-orphaned-tmux-stop-failed.log"))).not_to be_empty
    end
  end

  it "continues startup when a tmux socket disappears during inspection" do # @spec RAILS-CONTROL-PLANE-019
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, tmux: :socket_disappeared)
      socket = create_overmind_tmux_socket(dir)
      env = poll_env.merge(
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux")
      )

      _stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(true), stderr
      expect(File.exist?(socket)).to be(false)
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(true)
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(true)
      expect(File.read(File.join(dir, "calls.log"))).not_to include("tmux kill-session")
    end
  end

  it "tries to recover the dev environment when setup fails after stopping Overmind" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, setup_exit_status: 1, start_overmind_running: true)
      create_stale_socket(dir)

      env = poll_env.merge("PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}", "OVERMIND_SOCKET" => ".overmind.sock")
      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)
      updater_log = read_updater_log(dir)

      expect(status.success?).to be(false), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(File.join(dir, "overmind-quit-ran"))).to be(true)
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(true)
      expect(updater_log).to include("Setup failed after Overmind stop.")
      expect(updater_log).to include("Attempting recovery start because Overmind was stopped during this update.")
      expect(updater_log).to include("Recovery start succeeded.")
      expect(updater_log).to include("ERROR: Full restart aborted because bin/setup --skip-server failed.")
    end
  end

  it "fails loudly when restart does not restore a healthy Overmind session" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, dev_starts_overmind: false)

      env = poll_env.merge("PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}", "OVERMIND_SOCKET" => ".overmind.sock")
      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)
      updater_log = read_updater_log(dir)

      expect(status.success?).to be(false), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(true)
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(true)
      expect(Dir.glob(File.join(dir, "log", "dev-update", "diagnostics", "*dev-update-start-timeout.log"))).not_to be_empty
      expect(updater_log).to include("Inspect log/dev-update/dev-start.log for detached bin/dev output.")
      expect(updater_log).to include("ERROR: Full restart completed setup but failed to restore a healthy Overmind session.")
    end
  end

  it "restarts processes when Overmind is already healthy after setup" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, start_overmind_running: true)

      env = poll_env.merge("PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}", "OVERMIND_SOCKET" => ".overmind.sock")
      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)
      updater_log = read_updater_log(dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(true)
      expect(File.exist?(File.join(dir, "overmind-restart-ran"))).to be(true)
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(false)
      expect(updater_log).to include("overmind restart: overmind restarted processes")
      expect(updater_log).to include("Overmind is already running, restarting processes.")
      expect(updater_log).to include("Overmind process restart requested.")
    end
  end

  it "truncates oversized dev-update logs during configure_logging" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      log_dir = seed_oversized_logs(dir, 600_000)

      env = poll_env.merge(
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "OVERMIND_SOCKET" => ".overmind.sock",
        "DEV_UPDATE_MAX_LOG_BYTES" => "524288",
        "DEV_UPDATE_KEEP_LOG_BYTES" => "102400"
      )
      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(true), lambda {
        "bin/dev-update failed\nstdout:\n#{stdout}\nstderr:\n#{stderr}"
      }

      # Both logs were truncated to ~100 KB then appended to by the script/bin/dev
      expect(File.size(File.join(log_dir, "dev-update.log"))).to be < 200_000
      expect(File.size(File.join(log_dir, "dev-start.log"))).to be < 200_000
      expect(File.size(File.join(log_dir, "tmux.log"))).to be < 200_000
      expect(File.size(File.join(log_dir, "overmind.log"))).to be < 200_000
    end
  end

  it "preserves small dev-update logs without truncation" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)

      # Create a small log file
      log_dir = File.join(dir, "log", "dev-update")
      FileUtils.mkdir_p(log_dir)
      small_content = "previous run output\n" * 100
      File.write(File.join(log_dir, "dev-update.log"), small_content)

      env = poll_env.merge("PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}", "OVERMIND_SOCKET" => ".overmind.sock")
      stdout, stderr, status = Open3.capture3(env, script_path, "--lightweight", chdir: dir)

      expect(status.success?).to be(true), lambda {
        "bin/dev-update failed\nstdout:\n#{stdout}\nstderr:\n#{stderr}"
      }

      updater_log = File.read(File.join(log_dir, "dev-update.log"))
      # The small content should still be present (not truncated)
      expect(updater_log).to include("previous run output")
      # And new content was appended
      expect(updater_log).to include("Lightweight update complete.")
    end
  end

  it "keeps a persistent updater log outside the files bin/setup deletes" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)

      env = poll_env.merge("PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}", "OVERMIND_SOCKET" => ".overmind.sock")
      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      updater_log_path = File.join(dir, "log", "dev-update", "dev-update.log")
      dev_start_log_path = File.join(dir, "log", "dev-update", "dev-start.log")
      expect(File.exist?(updater_log_path)).to be(true)
      expect(File.exist?(dev_start_log_path)).to be(true)
      expect(File.read(updater_log_path)).to include("Starting full restart update...")
      expect(File.read(updater_log_path)).to include("Full restart update complete.")
      expect(wait_for_dev_start_log(dir)).to include("bin/dev booted")
    end
  end

  it "logs trigger context passed from the activity" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      stdout, stderr, status = Open3.capture3(
        trigger_context_env(dir,
          "DEV_UPDATE_TRIGGER_MODE" => "full",
          "DEV_UPDATE_PROJECT_ID" => "12",
          "DEV_UPDATE_PR_NUMBER" => "42",
          "DEV_UPDATE_CHANGED_FILES" => "app/models/user.rb\nbin/dev",
          "DEV_UPDATE_RESTART_TRIGGER_FILES" => "bin/dev"),
        script_path,
        "--full",
        chdir: dir
      )

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect_trigger_context_log(dir)
    end
  end

  it "upgrades lightweight mode to full restart when restart-worthy files are provided" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)

      stdout, stderr, status = Open3.capture3(
        trigger_context_env(dir,
          "DEV_UPDATE_TRIGGER_MODE" => "lightweight",
          "DEV_UPDATE_CHANGED_FILES" => "bin/dev\napp/models/user.rb"),
        script_path,
        "--lightweight",
        chdir: dir
      )

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(true)
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(true)

      updater_log = read_updater_log(dir)
      expect(updater_log).to include("Restart-worthy files were provided with a lightweight request; upgrading to full restart.")
      expect(updater_log).to include("Starting full restart update...")
      expect(updater_log).not_to include("Lightweight update complete. Rails will autoload changes.")
    end
  end

  it "upgrades lightweight to full restart when pull brings in restart-worthy files" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      diff_files = %w[app/models/user.rb config/initializers/temporal.rb]
      script_path = prepare_script_fixture(dir, pull_diff_files: diff_files)
      env = trigger_context_env(dir,
        "DEV_UPDATE_TRIGGER_MODE" => "lightweight",
        "DEV_UPDATE_CHANGED_FILES" => "app/models/user.rb")

      stdout, stderr, status = Open3.capture3(env, script_path, "--lightweight", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(true)
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(true)

      updater_log = read_updater_log(dir)
      expect(updater_log).to include("upgrading to full restart")
      expect(updater_log).to include("Full restart update complete.")
      expect(updater_log).not_to include("Lightweight update complete.")
    end
  end

  # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-002
  it "upgrades lightweight to full restart when pull brings in only worker-loaded service changes" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      # PR5271-style change: service code plus its spec, no app/temporal or
      # config files. Long-lived workers retain loaded constants, so this must
      # not complete as a "Rails will autoload changes" lightweight update.
      # The trigger context only reports docs, so the service change is
      # discovered from the pull diff after fetching.
      stdout, stderr, status = run_lightweight_with_pull(dir,
        pull_diff_files: %w[app/services/llm/request.rb spec/services/llm/request_spec.rb],
        changed_files: "docs/design.md")

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(true)
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(true)

      updater_log = read_updater_log(dir)
      expect(updater_log).to include("Pull included restart-worthy files outside the trigger context; upgrading to full restart.")
      expect(updater_log).to include("Full restart update complete.")
      expect(updater_log).not_to include("Lightweight update complete. Rails will autoload changes.")
    end
  end

  # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-002
  it "upgrades lightweight to full restart when the trigger context includes model and job changes" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)

      stdout, stderr, status = Open3.capture3(
        trigger_context_env(dir,
          "DEV_UPDATE_TRIGGER_MODE" => "lightweight",
          "DEV_UPDATE_CHANGED_FILES" => "app/models/runner.rb\napp/jobs/source_closure_recovery_job.rb"),
        script_path,
        "--lightweight",
        chdir: dir
      )

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(true)
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(true)

      updater_log = read_updater_log(dir)
      expect(updater_log).to include("Restart-worthy files were provided with a lightweight request; upgrading to full restart.")
      expect(updater_log).to include("Full restart update complete.")
      expect(updater_log).not_to include("Lightweight update complete. Rails will autoload changes.")
    end
  end

  # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-002
  it "stays lightweight when pull brings in only docs and web-autoloaded files" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      stdout, stderr, status = run_lightweight_with_pull(dir,
        pull_diff_files: %w[
          docs/intent/development-environment-update/development-environment-update-design.md
          app/controllers/projects_controller.rb
          app/views/projects/index.html.erb
          README.md
        ],
        changed_files: "docs/intent/development-environment-update/development-environment-update-design.md")

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(false)

      updater_log = read_updater_log(dir)
      expect(updater_log).to include("Lightweight update complete.")
      expect(updater_log).not_to include("upgrading to full restart")
    end
  end

  # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-003
  it "requests worker adoption once and verifies healthy worker readiness revisions after restart" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      stdout, stderr, status = run_lightweight_with_pull(dir,
        pull_diff_files: %w[app/services/llm/request.rb],
        changed_files: "app/services/llm/request.rb",
        start_overmind_running: true,
        with_stale_socket: true)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }

      # The graceful restart path was requested exactly once: one Overmind
      # stop, one dev start — no repeated restart attempts.
      calls = File.readlines(File.join(dir, "calls.log")).map(&:chomp)
      expect(calls.count("overmind quit")).to eq(1)
      expect(calls.count("dev")).to eq(1)
      expect(calls.count("setup --skip-server")).to eq(1)
      expect(File).not_to exist(File.join(dir, "worker-admission-barriers-held-at-stop"))

      updater_log = read_updater_log(dir)
      expect(updater_log).to include("Worker adoption verified: poll and agent workers report revision post-pull-sha.")

      # The readiness metadata proves the running workers booted the updated
      # checkout, using revision identity only (no process arguments/env).
      expect_worker_readiness_revision("post-pull-sha")
    end
  end

  # @spec TEMPORAL-ORCHESTRATION-019
  it "defers a full update before stopping the supervisor when a legacy worker is ready" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      stdout, stderr, status = run_lightweight_with_pull(dir,
        pull_diff_files: %w[app/services/llm/request.rb],
        changed_files: "app/services/llm/request.rb",
        start_overmind_running: true,
        with_stale_socket: true,
        worker_ready: true,
        worker_active_activities: 1)

      expect(status.success?).to be(false), -> { "expected failure but got success\nstdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.readlines(File.join(dir, "calls.log")).map(&:chomp)).to eq([ "git pull" ])

      updater_log = read_updater_log(dir)
      expect(updater_log).to include("does not support task-safe worker quiescence")
      expect(updater_log).to include("TEMPORAL-ORCHESTRATION-021")
      expect(updater_log).not_to include("Full restart update complete.")
    end
  end

  # @spec TEMPORAL-ORCHESTRATION-019
  it "defers an idle ready worker rather than treating activity count as admission safety" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      stdout, stderr, status = run_lightweight_with_pull(dir,
        pull_diff_files: %w[app/services/llm/request.rb],
        changed_files: "app/services/llm/request.rb",
        start_overmind_running: true,
        with_stale_socket: true,
        worker_ready: true)

      expect(status.success?).to be(false), "stdout: #{stdout}\nstderr: #{stderr}"
      expect(File.readlines(File.join(dir, "calls.log")).map(&:chomp)).to eq([ "git pull" ])
      expect(read_updater_log(dir)).to include("does not support task-safe worker quiescence")
    end
  end

  # @spec TEMPORAL-ORCHESTRATION-019
  it "defers a full update when a running Overmind reports Temporal workers without readiness metadata" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      # Models a worker that failed before mark_ready! (or whose readiness
      # marker was removed): Overmind still reports the worker processes, so
      # missing metadata must not be read as proof that no worker owns work.
      stdout, stderr, status = run_lightweight_with_pull(dir,
        pull_diff_files: %w[app/services/llm/request.rb],
        changed_files: "app/services/llm/request.rb",
        start_overmind_running: true,
        with_stale_socket: true,
        overmind_worker_processes: true)

      expect(status.success?).to be(false), -> { "expected failure but got success\nstdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.readlines(File.join(dir, "calls.log")).map(&:chomp)).to eq([ "git pull" ])
      expect(File.exist?(File.join(dir, "overmind-quit-ran"))).to be(false)

      updater_log = read_updater_log(dir)
      expect(updater_log).to include("readiness metadata is missing and no safe no-worker supervisor state was verified; deferring worker adoption before stopping Overmind.")
      expect(updater_log).not_to include("Full restart update complete.")
    end
  end

  # @spec TEMPORAL-ORCHESTRATION-019
  it "defers a full update when a stale control socket leaves a worker-bearing orphaned tmux session" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      # A stale socket does not authorize force-killing its worker-bearing orphan.
      script_path = prepare_script_fixture(
        dir,
        start_overmind_running: true,
        tmux: :same_workspace,
        overmind_status_exit_status: 1,
        pull_diff_files: %w[app/services/llm/request.rb]
      )
      create_overmind_tmux_socket(dir)
      create_stale_socket(dir)
      env = stale_socket_worker_orphan_env(dir)

      _stdout, _stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(false)
      expect(File.readlines(File.join(dir, "calls.log")).map(&:chomp)).to eq([ "git pull" ])
      expect(File.exist?(File.join(dir, "overmind-quit-ran"))).to be(false)
      expect(File.read(File.join(dir, "calls.log"))).not_to include("tmux kill-session")
      expect(read_updater_log(dir)).to include("no safe no-worker supervisor state was verified")
    end
  end

  # @spec TEMPORAL-ORCHESTRATION-019
  it "defers a full update when overmind status exits successfully with unparseable output" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      # A zero exit status only proves the command ran, not that its output
      # parsed as status rows. Garbled text contains no "worker_poll"/
      # "worker_agent" row not because none exists, but because nothing
      # parsed; this must not be read as verified absence of a worker.
      script_path = prepare_script_fixture(dir,
        pull_diff_files: %w[app/services/llm/request.rb],
        start_overmind_running: true,
        overmind_status_malformed: true)
      env = trigger_context_env(dir,
        "DEV_UPDATE_TRIGGER_MODE" => "lightweight",
        "DEV_UPDATE_CHANGED_FILES" => "app/services/llm/request.rb")

      stdout, stderr, status = with_active_overmind_socket(dir) do
        Open3.capture3(env, script_path, "--lightweight", chdir: dir)
      end

      expect(status.success?).to be(false), -> { "expected failure but got success\nstdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.readlines(File.join(dir, "calls.log")).map(&:chomp)).to eq([ "git pull" ])
      expect(File.exist?(File.join(dir, "overmind-quit-ran"))).to be(false)

      updater_log = read_updater_log(dir)
      expect(updater_log).to include("overmind status output did not match the expected PROCESS/PID/STATUS format")
      expect(updater_log).not_to include("Full restart update complete.")
    end
  end

  # @spec TEMPORAL-ORCHESTRATION-019
  it "defers an unsuffixed legacy marker even when supervisor rows look worker-free" do # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-006
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, start_overmind_running: true)
      legacy = File.join(ENV.fetch("TMPDIR"), "paid-worker-ready-temporal_worker")
      File.write(legacy, { pid: 12_345, revision: "legacy" }.to_json)
      env = poll_env.merge("PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}")

      _stdout, _stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(false)
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(false)
      expect(File.read(File.join(dir, "calls.log"))).not_to include("overmind quit")
    end
  end

  it "proceeds without worker quiescence when a running Overmind reports no Temporal worker processes" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      stdout, stderr, status = run_lightweight_with_pull(dir,
        pull_diff_files: %w[app/services/llm/request.rb],
        changed_files: "app/services/llm/request.rb",
        start_overmind_running: true,
        with_stale_socket: true)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }

      updater_log = read_updater_log(dir)
      expect(updater_log).to include("no Temporal worker is running; no Temporal worker quiescence is required.")
      expect(updater_log).to include("Full restart update complete.")
    end
  end

  # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-003
  it "fails the update when a restarted worker reports a stale revision" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      stdout, stderr, status = run_lightweight_with_pull(dir,
        pull_diff_files: %w[app/services/llm/request.rb],
        changed_files: "app/services/llm/request.rb",
        start_overmind_running: true,
        with_stale_socket: true,
        worker_readiness_revision: "stale-worker-sha")

      expect(status.success?).to be(false), -> { "expected failure but got success\nstdout: #{stdout}\nstderr: #{stderr}" }
      updater_log = read_updater_log(dir)
      expect(updater_log).to include("poll worker readiness at")
      expect(updater_log).to include("did not report revision post-pull-sha")
      expect(updater_log).to include("Workers did not adopt the updated checkout; update cannot be considered complete.")
      expect(updater_log).not_to include("Full restart update complete.")
    end
  end

  # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-003
  it "fails the update without claiming completion when the checkout revision is unknown" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      stdout, stderr, status = run_lightweight_with_pull(dir,
        pull_diff_files: %w[app/services/llm/request.rb],
        changed_files: "app/services/llm/request.rb",
        start_overmind_running: true,
        with_stale_socket: true,
        unknown_checkout_head: true)

      expect(status.success?).to be(false), -> { "expected failure but got success\nstdout: #{stdout}\nstderr: #{stderr}" }
      # The restarted environment came up; the failure is the fail-closed
      # adoption check, not a crash before start.
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(true)
      updater_log = read_updater_log(dir)
      expect(updater_log).to include("git rev-parse HEAD failed; the expected worker revision is unknown.")
      expect(updater_log).to include("update cannot be considered complete. Resolve the Git checkout state and rerun bin/dev-update --full.")
      expect(updater_log).not_to include("Worker adoption verified")
      expect(updater_log).not_to include("adopted revision")
      expect(updater_log).not_to include("Full restart update complete.")
    end
  end

  it "runs migrations before restarting when trigger context includes migration files" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, start_overmind_running: true)
      create_stale_socket(dir)

      stdout, stderr, status = run_with_migration_trigger(dir, script_path, "--full")

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect_calls(dir, migration_restart_calls("overmind quit"))

      updater_log = read_updater_log(dir)
      expect(updater_log).to include("stopping Overmind before pulling")
      expect(updater_log).to include("Migration files changed; running bin/rails db:migrate before restart...")
      expect(updater_log).to include("Database migrations are current.")
    end
  end

  it "runs migrations before restarting when pull brings in migration files" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, pull_diff_files: %w[
        app/models/user.rb
        db/migrate/20260722000000_add_widgets.rb
      ])

      result = Open3.capture3(
        trigger_context_env(dir,
          "DEV_UPDATE_TRIGGER_MODE" => "lightweight",
          "DEV_UPDATE_CHANGED_FILES" => "app/models/user.rb"),
        script_path,
        "--lightweight",
        chdir: dir
      )
      stdout, stderr, status = result

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect_calls(dir, migration_restart_calls)
    end
  end

  it "fails before restart when explicit migration run fails" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, rails_migrate_exit_status: 1)

      stdout, stderr, status = run_with_migration_trigger(dir, script_path, "--full")

      expect(status.success?).to be(false), -> { "expected failure but got success\nstdout: #{stdout}\nstderr: #{stderr}" }
      expect_calls(dir, migration_restart_calls[0...-2])

      updater_log = read_updater_log(dir)
      expect(updater_log).to include("db:migrate: migration failed")
      expect(updater_log).to include("ERROR: bin/rails db:migrate failed. Fix the migration and rerun bin/dev-update --full.")
    end
  end

  it "recovers Overmind when a migration-triggered update stops before a failed pull" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, start_overmind_running: true, pull_exit_status: 1)
      create_stale_socket(dir)

      stdout, stderr, status = Open3.capture3(
        trigger_context_env(dir,
          "DEV_UPDATE_TRIGGER_MODE" => "full",
          "DEV_UPDATE_CHANGED_FILES" => "db/migrate/20260722000000_add_widgets.rb",
          "DEV_UPDATE_RESTART_TRIGGER_FILES" => "db/migrate/20260722000000_add_widgets.rb"),
        script_path,
        "--full",
        chdir: dir
      )

      expect(status.success?).to be(false), -> { "expected failure but got success\nstdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(true)
      expect(read_updater_log(dir)).to include("Recovery start succeeded.")
      expect(read_updater_log(dir)).to include("ERROR: git pull --ff-only failed.")
    end
  end

  it "recovers Overmind when a migration-triggered update stops before a dirty branch abort" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, start_overmind_running: true, current_branch: "feature/fix", dirty_tree: true)
      create_stale_socket(dir)

      stdout, stderr, status = run_with_migration_trigger(dir, script_path, "--full")

      expect(status.success?).to be(false), -> { "expected failure but got success\nstdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(true)
      expect(read_updater_log(dir)).to include("Recovery start succeeded.")
      expect(read_updater_log(dir)).to include("ERROR: Cannot update while the current branch has uncommitted changes.")
    end
  end

  it "does not forward STARTUP_CLEANUP_KILL_ALL when unset during full restart" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, capture_kill_all_in_dev: true)

      env = poll_env.merge(
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "OVERMIND_SOCKET" => ".overmind.sock",
        "DEV_UPDATE_STARTUP_CLEANUP_KILL_ALL" => nil
      )
      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.read(File.join(dir, "setup-env.log"))).to eq("\n")
      expect(File.read(File.join(dir, "dev-env.log"))).to eq("\n")
    end
  end

  it "forwards STARTUP_CLEANUP_KILL_ALL to both setup and dev during full restart" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, capture_kill_all_in_dev: true)

      env = poll_env.merge(
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "OVERMIND_SOCKET" => ".overmind.sock",
        "DEV_UPDATE_STARTUP_CLEANUP_KILL_ALL" => "1"
      )
      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.read(File.join(dir, "setup-env.log"))).to eq("1\n")
      expect(File.read(File.join(dir, "dev-env.log"))).to eq("1\n")
    end
  end

  it "unsets PORT before launching bin/dev so the default base port is used" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, capture_port_in_dev: true)

      env = poll_env.merge(
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "OVERMIND_SOCKET" => ".overmind.sock",
        "PORT" => "3300"
      )
      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      port_log = File.join(dir, "dev-port.log")
      expect(File.exist?(port_log)).to be(true)
      expect(File.read(port_log).strip).to eq(""), "PORT should be unset when bin/dev is launched"
    end
  end

  it "treats disown as best-effort after launching detached bin/dev" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      bash_env = File.join(dir, "disable-disown.sh")
      File.write(bash_env, "enable -n disown || true\n")

      env = poll_env.merge(
        "BASH_ENV" => bash_env,
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "OVERMIND_SOCKET" => ".overmind.sock"
      )
      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(true)
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(true)
    end
  end

  it "clears bundler env before calling overmind during restart" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, start_overmind_running: true)
      env = poll_env.merge(bundler_contaminated_env(dir))
      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      log = overmind_invocation_log(dir)
      expect(log).to include("CMD=restart")
      restart_block = log.split("\n--\n").find { |block| block.lines.first&.start_with?("CMD=restart") }
      expect(restart_block).not_to include("BUNDLE_GEMFILE=")
      expect(restart_block).not_to include("RUBYOPT=")
      expect(File.exist?(File.join(dir, "overmind-restart-ran"))).to be(true)
    end
  end

  it "clears bundler env before calling bin/setup" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, capture_bundler_env_in_setup: true)
      env = poll_env.merge(bundler_contaminated_env(dir))

      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      setup_env_log = File.read(File.join(dir, "setup-bundler-env.log"))
      expect(setup_env_log).not_to include("BUNDLE_GEMFILE=")
      expect(setup_env_log).not_to include("RUBYOPT=")
    end
  end

  it "clears bundler env before launching detached bin/dev" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, capture_bundler_env_in_dev: true)
      env = poll_env.merge(bundler_contaminated_env(dir))

      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      dev_env_log = File.read(File.join(dir, "dev-bundler-env.log"))
      expect(dev_env_log).not_to include("BUNDLE_GEMFILE=")
      expect(dev_env_log).not_to include("RUBYOPT=")
      expect(dev_env_log).not_to include("TMUX=")
    end
  end

  it "requires consecutive healthy overmind polls before declaring restart success" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, status_successes_after_start: 1)
      env = poll_env.merge(
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "OVERMIND_SOCKET" => ".overmind.sock",
        "DEV_UPDATE_OVERMIND_HEALTHY_CONFIRM_COUNT" => "2"
      )

      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)
      updater_log = read_updater_log(dir)

      expect(status.success?).to be(false), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(updater_log).to include("Inspect log/dev-update/dev-start.log for detached bin/dev output.")
      expect(updater_log).to include("ERROR: Full restart completed setup but failed to restore a healthy Overmind session.")
    end
  end

  it "does not treat overmind restart as success unless health persists" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      # The worker-quiescence gate consumes one successful `overmind status`
      # call before start_dev runs, so the budget allows that first success.
      script_path = prepare_script_fixture(dir, start_overmind_running: true, status_successes_after_start: 2)
      env = poll_env.merge(
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "OVERMIND_SOCKET" => ".overmind.sock",
        "DEV_UPDATE_OVERMIND_HEALTHY_CONFIRM_COUNT" => "2"
      )

      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)
      updater_log = read_updater_log(dir)

      expect(status.success?).to be(false), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(File.join(dir, "overmind-restart-ran"))).to be(true)
      expect(updater_log).to include("Overmind is already running, restarting processes.")
      expect(updater_log).to include("Inspect log/dev-update/dev-start.log for detached bin/dev output.")
      expect(updater_log).to include("ERROR: Full restart completed setup but failed to restore a healthy Overmind session.")
    end
  end

  it "auto-stashes dirty working tree before pulling" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, dirty_tree: true)

      env = poll_env.merge("PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}", "OVERMIND_SOCKET" => ".overmind.sock")
      stdout, stderr, status = Open3.capture3(env, script_path, "--lightweight", chdir: dir)
      updater_log = read_updater_log(dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(updater_log).to include("Working tree has uncommitted changes; auto-stashing...")
      expect(updater_log).to include("Restoring auto-stashed changes...")
      expect(updater_log).to include("Lightweight update complete.")
    end
  end

  # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-001
  it "aborts after a failed auto-stash without pulling or popping a pre-existing stash" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(
        dir,
        dirty_tree: true,
        stash_push_exit_status: 1,
        stash_push_output: "fatal: Unable to create .git/index.lock",
        pre_existing_stash: true
      )

      stdout, stderr, status = Open3.capture3(failure_lock_env(dir), script_path, "--lightweight", chdir: dir)
      updater_log = read_updater_log(dir)
      lock_path = File.join(dir, "tmp", "dev-update-failure.lock")

      expect(status.success?).to be(false), -> { "expected failure but got success\nstdout: #{stdout}\nstderr: #{stderr}" }
      expect(updater_log).to include("git stash: fatal: Unable to create .git/index.lock")
      expect(updater_log).to include("ERROR: git stash push failed. Resolve the Git error and rerun bin/dev-update.")
      expect(File.exist?(File.join(dir, "pull-ran"))).to be(false)
      expect(File.read(File.join(dir, "git-stash.log"))).to eq("stash: stash push --include-untracked -m dev-update-autostash\n")
      expect(File.exist?(File.join(dir, "pre-existing-stash"))).to be(true)
      expect(File.read(lock_path).strip).to eq("1")
      expect(File.read("#{lock_path}.reason").strip).to eq("git-stash")
    end
  end

  # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-001
  it "recovers Overmind when a migration-triggered update stops before a failed auto-stash" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(
        dir,
        start_overmind_running: true,
        dirty_tree: true,
        stash_push_exit_status: 1,
        stash_push_output: "fatal: Unable to create .git/index.lock"
      )
      create_stale_socket(dir)

      stdout, stderr, status = run_with_migration_trigger(dir, script_path, "--full")

      expect(status.success?).to be(false), -> { "expected failure but got success\nstdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(File.join(dir, "dev-ran"))).to be(true), -> { read_updater_log(dir) }
      updater_log = read_updater_log(dir)
      expect(updater_log).to include("Attempting recovery start because Overmind was stopped during this update.")
      expect(updater_log).to include("Recovery start succeeded.")
      expect(updater_log).to include("ERROR: git stash push failed. Resolve the Git error and rerun bin/dev-update.")
    end
  end

  # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-001
  it "skips restore without popping when a successful push creates no stash" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(
        dir,
        dirty_tree: true,
        stash_push_output: "No local changes to save",
        pre_existing_stash: true
      )

      env = poll_env.merge("PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}", "OVERMIND_SOCKET" => ".overmind.sock")
      stdout, stderr, status = Open3.capture3(env, script_path, "--lightweight", chdir: dir)
      updater_log = read_updater_log(dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(updater_log).to include("Working tree has uncommitted changes; auto-stashing...")
      expect(updater_log).to include("git stash: No local changes to save")
      expect(updater_log).to include("Auto-stash created no stash entry; skipping restore.")
      expect(updater_log).not_to include("Restoring auto-stashed changes...")
      expect(updater_log).to include("Lightweight update complete.")
      expect(File.read(File.join(dir, "git-stash.log"))).to eq("stash: stash push --include-untracked -m dev-update-autostash\n")
      expect(File.exist?(File.join(dir, "pre-existing-stash"))).to be(true)
      expect(File.read(File.join(dir, "refs-stash")).strip).to eq("pre-existing-stash-sha")
    end
  end

  it "logs git stash pop output after restoring auto-stashed changes" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, dirty_tree: true, stash_pop_output: "Applied autostash cleanly")

      env = poll_env.merge("PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}", "OVERMIND_SOCKET" => ".overmind.sock")
      stdout, stderr, status = Open3.capture3(env, script_path, "--lightweight", chdir: dir)
      updater_log = read_updater_log(dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(updater_log).to include("git stash pop: Applied autostash cleanly")
    end
  end

  it "aborts with error when git stash pop conflicts during restore" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(
        dir,
        dirty_tree: true,
        stash_pop_exit_status: 1,
        stash_pop_output: "CONFLICT (content): Merge conflict in bin/dev-update"
      )

      env = poll_env.merge("PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}", "OVERMIND_SOCKET" => ".overmind.sock")
      stdout, stderr, status = Open3.capture3(env, script_path, "--lightweight", chdir: dir)
      updater_log = read_updater_log(dir)

      expect(status.success?).to be(false), -> { "expected failure but got success\nstdout: #{stdout}\nstderr: #{stderr}" }
      expect(updater_log).to include("git stash pop: CONFLICT (content): Merge conflict in bin/dev-update")
      expect(updater_log).to include("ERROR: git stash pop failed (conflict). Resolve manually with 'git stash pop'.")
    end
  end

  it "stops retrying after max consecutive pull failures" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)

      # Seed the failure lock at the max
      FileUtils.mkdir_p(File.join(dir, "tmp"))
      File.write(File.join(dir, "tmp", "dev-update-failure.lock"), "3")

      env = poll_env.merge(
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "OVERMIND_SOCKET" => ".overmind.sock",
        "DEV_UPDATE_MAX_CONSECUTIVE_FAILURES" => "3"
      )
      stdout, stderr, status = Open3.capture3(env, script_path, "--lightweight", chdir: dir)
      updater_log = read_updater_log(dir)

      expect(status.success?).to be(false), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(updater_log).to include("consecutive pull failures detected. Manual intervention required.")
    end
  end

  it "self-clears a dirty non-main failure lock once the working tree is clean" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, current_branch: "feature/fix", dirty_tree: false)
      lock_path, reason_path = seed_failure_lock(dir, reason: "dirty-non-main")

      stdout, stderr, status = Open3.capture3(failure_lock_env(dir), script_path, "--lightweight", chdir: dir)
      updater_log = read_updater_log(dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(updater_log).to include("Failure lock was caused by dirty non-main branch")
      expect(updater_log).to include("Cleared failure lock after resolved working-tree condition.")
      expect(updater_log).to include("Switching to main branch (currently on feature/fix)...")
      expect(updater_log).to include("Lightweight update complete.")
      expect(File.exist?(lock_path)).to be(false)
      expect(File.exist?(reason_path)).to be(false)
    end
  end

  it "self-clears a legacy count-only lock on a clean non-main branch" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, current_branch: "feature/fix", dirty_tree: false)
      lock_path, = seed_failure_lock(dir)

      stdout, stderr, status = Open3.capture3(failure_lock_env(dir), script_path, "--lightweight", chdir: dir)
      updater_log = read_updater_log(dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(updater_log).to include("Legacy failure lock found on clean non-main branch")
      expect(updater_log).to include("Cleared failure lock after resolved working-tree condition.")
      expect(updater_log).to include("Lightweight update complete.")
      expect(File.exist?(lock_path)).to be(false)
    end
  end

  it "records and clears failure lock on pull success" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)

      # Seed a failure lock below the max
      FileUtils.mkdir_p(File.join(dir, "tmp"))
      lock_path = File.join(dir, "tmp", "dev-update-failure.lock")
      File.write(lock_path, "1")

      env = poll_env.merge(
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "OVERMIND_SOCKET" => ".overmind.sock",
        "DEV_UPDATE_MAX_CONSECUTIVE_FAILURES" => "3"
      )
      stdout, stderr, status = Open3.capture3(env, script_path, "--lightweight", chdir: dir)
      updater_log = read_updater_log(dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(updater_log).to include("Cleared failure lock after successful pull.")
      expect(File.exist?(lock_path)).to be(false)
    end
  end

  it "records pull failure and exits with error" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, pull_exit_status: 1)

      env = poll_env.merge(
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "OVERMIND_SOCKET" => ".overmind.sock",
        "DEV_UPDATE_MAX_CONSECUTIVE_FAILURES" => "3"
      )
      stdout, stderr, status = Open3.capture3(env, script_path, "--lightweight", chdir: dir)
      updater_log = read_updater_log(dir)

      expect(status.success?).to be(false), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(updater_log).to include("Recorded pull failure (1/3).")
      expect(updater_log).to include("ERROR: git pull --ff-only failed.")

      lock_path = File.join(dir, "tmp", "dev-update-failure.lock")
      expect(File.exist?(lock_path)).to be(true)
      expect(File.read(lock_path).strip).to eq("1")
    end
  end

  def write_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod("+x", path)
  end

  def read_updater_log(dir)
    File.read(File.join(dir, "log", "dev-update", "dev-update.log"))
  end

  def worker_readiness_path(mode)
    File.join(ENV.fetch("TMPDIR", "/tmp"), "paid-worker-ready-temporal_worker-#{mode}")
  end

  def worker_readiness_payload(mode)
    JSON.parse(File.read(worker_readiness_path(mode)))
  end

  def expect_worker_readiness_revision(revision)
    %w[poll agent].each do |mode|
      payload = worker_readiness_payload(mode)
      expect(payload["revision"]).to eq(revision)
      expect(payload.keys).to match_array(%w[pid ready_at revision active_activities])
    end
  end

  # Runs a lightweight request whose trigger context reports changed_files
  # while the pull diff brings in pull_diff_files, returning the captured
  # result of bin/dev-update --lightweight. Creates a stale Overmind socket
  # before the run when with_stale_socket is set so the stop path executes.
  def run_lightweight_with_pull(dir, pull_diff_files:, changed_files:, with_stale_socket: false, **fixture_args)
    script_path = prepare_script_fixture(dir, pull_diff_files: pull_diff_files, **fixture_args)
    create_stale_socket(dir) if with_stale_socket
    env = trigger_context_env(dir,
      "DEV_UPDATE_TRIGGER_MODE" => "lightweight",
      "DEV_UPDATE_CHANGED_FILES" => changed_files)
    Open3.capture3(env, script_path, "--lightweight", chdir: dir)
  end

  def run_cross_role_arrival(dir)
    script_path = prepare_script_fixture(dir,
      pull_diff_files: %w[app/services/llm/request.rb],
      start_overmind_running: true)
    create_stale_socket(dir)
    agent_readiness = worker_readiness_path("agent")
    agent_payload = JSON.parse(File.read(agent_readiness)).merge("active_activities" => 1)
    File.write(agent_readiness, agent_payload.to_json)

    File.open("#{agent_readiness}.admission.lock", File::RDWR | File::CREAT, 0o644) do |agent_lock|
      agent_lock.flock(File::LOCK_SH)
      run_update_during_agent_activity(dir, script_path, agent_readiness, agent_payload, agent_lock)
    end
  end

  def run_update_during_agent_activity(dir, script_path, agent_readiness, agent_payload, agent_lock)
    env = trigger_context_env(dir,
      "DEV_UPDATE_TRIGGER_MODE" => "lightweight",
      "DEV_UPDATE_CHANGED_FILES" => "app/services/llm/request.rb")
    Open3.popen3(env, script_path, "--lightweight", chdir: dir) do |stdin, stdout, stderr, wait_thread|
      stdin.close
      stdout_reader = Thread.new { stdout.read }
      stderr_reader = Thread.new { stderr.read }
      wait_for_poll_admission_to_close(dir)
      poll_admitted = poll_arrival_admitted?
      File.write(agent_readiness, agent_payload.merge("active_activities" => 0).to_json)
      agent_lock.flock(File::LOCK_UN)
      [ wait_thread.value, poll_admitted, stderr_reader.value ]
    ensure
      Process.kill("TERM", wait_thread.pid) if wait_thread&.alive?
      stdout_reader&.join
      stderr_reader&.join
    end
  end

  def wait_for_poll_admission_to_close(dir)
    Timeout.timeout(5) do
      Thread.pass until File.exist?(File.join(dir, "log", "dev-update", "dev-update.log")) &&
        read_updater_log(dir).include?("Worker (poll) activity admission is closed")
    end
  end

  def poll_arrival_admitted?
    File.open("#{worker_readiness_path('poll')}.admission.lock", File::RDWR | File::CREAT, 0o644) do |lock|
      lock.flock(File::LOCK_SH | File::LOCK_NB) != false
    end
  end

  def expect_calls(dir, expected)
    expect(File.read(File.join(dir, "calls.log")).lines.map(&:chomp)).to eq(expected)
  end

  def expect_trigger_context_log(dir)
    updater_log = read_updater_log(dir)
    expect(updater_log).to include("Trigger source: Activities::TriggerDevEnvironmentUpdateActivity")
    expect(updater_log).to include("Requested mode: full")
    expect(updater_log).to include("Project ID: 12")
    expect(updater_log).to include("PR number: 42")
    expect(updater_log).to include("Changed files: app/models/user.rb,bin/dev")
    expect(updater_log).to include("Restart trigger files: bin/dev")
  end

  def trigger_context_env(dir, overrides = {})
    poll_env.merge(
      {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "OVERMIND_SOCKET" => ".overmind.sock",
        "DEV_UPDATE_TRIGGER_SOURCE" => "Activities::TriggerDevEnvironmentUpdateActivity"
      }.merge(overrides)
    )
  end

  def migration_trigger_env(dir)
    trigger_context_env(dir,
      "DEV_UPDATE_TRIGGER_MODE" => "full",
      "DEV_UPDATE_CHANGED_FILES" => "db/migrate/20260722000000_add_widgets.rb",
      "DEV_UPDATE_RESTART_TRIGGER_FILES" => "db/migrate/20260722000000_add_widgets.rb")
  end

  def run_with_migration_trigger(dir, script_path, mode)
    Open3.capture3(migration_trigger_env(dir), script_path, mode, chdir: dir)
  end

  def migration_restart_calls(*prefix)
    [
      *prefix,
      "git pull",
      "setup --skip-server --skip-database",
      "ensure-worktree-databases",
      "rails db:migrate",
      "rails prompts:sync_defaults",
      "dev"
    ]
  end

  def failure_lock_env(dir)
    poll_env.merge(
      "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
      "OVERMIND_SOCKET" => ".overmind.sock",
      "DEV_UPDATE_MAX_CONSECUTIVE_FAILURES" => "3"
    )
  end

  def seed_failure_lock(dir, reason: nil)
    FileUtils.mkdir_p(File.join(dir, "tmp"))
    lock_path = File.join(dir, "tmp", "dev-update-failure.lock")
    reason_path = "#{lock_path}.reason"
    File.write(lock_path, "3")
    File.write(reason_path, reason) if reason
    [ lock_path, reason_path ]
  end

  def wait_for_dev_start_log(dir)
    dev_start_log = nil

    Timeout.timeout(5) do
      loop do
        dev_start_log_path = File.join(dir, "log", "dev-update", "dev-start.log")
        dev_start_log = File.read(dev_start_log_path) if File.exist?(dev_start_log_path)
        break if dev_start_log&.include?("bin/dev booted")

        sleep 0.1
      end
    end

    dev_start_log
  end

  def seed_oversized_logs(dir, size)
    log_dir = File.join(dir, "log", "dev-update")
    FileUtils.mkdir_p(log_dir)
    %w[dev-update.log dev-start.log tmux.log overmind.log].each { |f| File.write(File.join(log_dir, f), "x" * size) }
    log_dir
  end

  def prepare_script_fixture(
    dir,
    setup_exit_status: 0,
    start_overmind_running: false,
    dev_starts_overmind: true,
    capture_bundler_env_in_setup: false,
    capture_bundler_env_in_dev: false,
    capture_port_in_dev: false,
    capture_kill_all_in_dev: false,
    dirty_tree: false,
    current_branch: "main",
    pull_exit_status: 0,
    stash_push_exit_status: 0,
    stash_push_output: "Saved working directory and index state",
    stash_pop_exit_status: 0,
    stash_pop_output: "Applied stash",
    pre_existing_stash: false,
    pull_diff_files: [],
    rails_migrate_exit_status: 0,
    rails_sync_exit_status: 0,
    status_successes_after_start: nil,
    tmux: nil,
    worker_readiness_revision: nil,
    worker_ready: false,
    overmind_worker_processes: false,
    overmind_status_exit_status: 0,
    overmind_status_malformed: false,
    unknown_checkout_head: false,
    worker_active_activities: 0
  )
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.mkdir_p(File.join(dir, "bin", "lib"))
    FileUtils.mkdir_p(File.join(dir, "log"))
    FileUtils.mkdir_p(File.join(dir, "stubbin"))

    FileUtils.touch(File.join(dir, "overmind-running")) if start_overmind_running
    if start_overmind_running && worker_ready
      %w[poll agent].each do |mode|
        File.write(
          worker_readiness_path(mode),
          { pid: 12_345, ready_at: Time.now.utc.iso8601, revision: "pre-pull-sha", active_activities: worker_active_activities }.to_json
        )
      end
    end
    FileUtils.touch(File.join(dir, "pre-existing-stash")) if pre_existing_stash
    # Model refs/stash: a pre-existing stash occupies the ref until a push
    # creates a new entry or a successful pop consumes it.
    File.write(File.join(dir, "refs-stash"), "pre-existing-stash-sha\n") if pre_existing_stash

    script_path = File.join(dir, "bin", "dev-update")
    FileUtils.cp(script_source, script_path)
    FileUtils.chmod("+x", script_path)
    FileUtils.cp(File.expand_path("../../bin/lib/dev_supervisor.sh", __dir__), File.join(dir, "bin", "lib", "dev_supervisor.sh"))
    %w[dev_worker_admission.sh worker_admission.py worker_admission_cohort.py].each do |name|
      FileUtils.cp(File.expand_path("../../bin/lib/#{name}", __dir__), File.join(dir, "bin", "lib", name))
    end

    # Models the real Temporal workers' readiness flags: when a stub worker
    # boots it publishes its boot revision so bin/dev-update can verify
    # effective worker adoption. An explicit worker_readiness_revision forces
    # a stale worker that never adopts the updated checkout.
    write_executable(
      File.join(dir, "write-worker-readiness"),
      <<~BASH
        #!/usr/bin/env bash
        set -euo pipefail
        revision="${1:-}"
        if [ -z "$revision" ]; then
          revision="$(git rev-parse HEAD 2>/dev/null || true)"
        fi
        for mode in poll agent; do
          file="${TMPDIR:-/tmp}/paid-worker-ready-temporal_worker-${mode}"
          mkdir -p "$(dirname "$file")"
          printf '{"pid":%s,"ready_at":"%s","revision":"%s","active_activities":%s}\\n' "$$" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${revision}" "#{worker_active_activities}" > "$file"
        done
      BASH
    )
    write_worker_readiness_line = %("#{dir}/write-worker-readiness" "#{worker_readiness_revision || ''}")

    # Models a checkout whose HEAD can no longer be resolved once the workers
    # boot (for example a corrupted .git between the pull and verification):
    # the stub git fails `rev-parse HEAD` from then on, so bin/dev-update
    # cannot determine the expected worker revision.
    unknown_head_line = unknown_checkout_head ? %(touch "#{dir}/head-unknown") : ""

    dev_start_line = dev_starts_overmind ? %(touch "#{dir}/overmind-running") : ""
    capture_port_line = capture_port_in_dev ? %(printf '%s\n' "${PORT:-}" > "#{dir}/dev-port.log") : ""
    capture_kill_all_line =
      capture_kill_all_in_dev ? %(printf '%s\n' "${STARTUP_CLEANUP_KILL_ALL:-}" > "#{dir}/dev-env.log") : ""
    capture_setup_bundler_line =
      capture_bundler_env_in_setup ? %((env | sort | grep -E '^(BUNDLE_GEMFILE|BUNDLE_BIN_PATH|BUNDLER_SETUP|BUNDLER_VERSION|RUBYLIB|RUBYOPT|RUBYGEMS_GEMDEPS|TMUX)=' || true) > "#{dir}/setup-bundler-env.log") : ""
    capture_dev_bundler_line =
      capture_bundler_env_in_dev ? %((env | sort | grep -E '^(BUNDLE_GEMFILE|BUNDLE_BIN_PATH|BUNDLER_SETUP|BUNDLER_VERSION|RUBYLIB|RUBYOPT|RUBYGEMS_GEMDEPS|TMUX)=' || true) > "#{dir}/dev-bundler-env.log") : ""

    write_executable(
      File.join(dir, "bin", "setup"),
      <<~BASH
        #!/usr/bin/env bash
        touch "#{dir}/setup-ran"
        echo "${PAID_SKIP_AUTO_SCHEMA_DUMP:-}" > "#{dir}/setup-schema-env.log"
        printf 'setup %s\\n' "$*" >> "#{dir}/calls.log"
        printf '%s\n' "${STARTUP_CLEANUP_KILL_ALL:-}" > "#{dir}/setup-env.log"
        #{capture_setup_bundler_line}
        exit #{setup_exit_status}
      BASH
    )

    write_executable(
      File.join(dir, "bin", "ensure-worktree-databases"),
      <<~BASH
        #!/usr/bin/env bash
        printf 'ensure-worktree-databases\\n' >> "#{dir}/calls.log"
        exit 0
      BASH
    )

    write_executable(
      File.join(dir, "bin", "rails"),
      <<~BASH
        #!/usr/bin/env bash
        printf 'rails %s\\n' "$*" >> "#{dir}/calls.log"
        if [ "$*" = "db:migrate" ]; then
          echo "${PAID_SKIP_AUTO_SCHEMA_DUMP:-}" > "#{dir}/migrate-schema-env.log"
          if [ "#{rails_migrate_exit_status}" -eq 0 ]; then
            echo "migrated"
          else
            echo "migration failed" >&2
          fi
          exit #{rails_migrate_exit_status}
        fi
        if [ "$*" = "prompts:sync_defaults" ]; then
          if [ "#{rails_sync_exit_status}" -eq 0 ]; then
            echo "Prompt defaults synchronized"
          else
            echo "prompt sync failed" >&2
          fi
          exit #{rails_sync_exit_status}
        fi
        exit 0
      BASH
    )

    write_executable(
      File.join(dir, "bin", "dev"),
      <<~BASH
        #!/usr/bin/env bash
        touch "#{dir}/dev-ran"
        printf 'dev\\n' >> "#{dir}/calls.log"
        #{capture_port_line}
        #{capture_kill_all_line}
        #{capture_dev_bundler_line}
        #{unknown_head_line}
        #{write_worker_readiness_line}
        #{dev_start_line}
        echo "bin/dev booted"
      BASH
    )

    dirty_status_output = dirty_tree ? " M dirty-file.txt" : ""
    pull_diff_file = File.join(dir, "pull-diff-files")
    File.write(pull_diff_file, pull_diff_files.join("\n"))
    write_executable(
      File.join(dir, "stubbin", "git"),
      <<~BASH
        #!/usr/bin/env bash
        case "$1" in
          rev-parse)
            case "${2:-}" in
              --abbrev-ref)
                echo "#{current_branch}"
                ;;
              --verify)
                if [ "${4:-}" = "refs/stash" ] && [ -f "#{dir}/refs-stash" ]; then
                  cat "#{dir}/refs-stash"
                else
                  exit 1
                fi
                ;;
              *)
                if [ -e "#{dir}/head-unknown" ]; then
                  echo "fatal: unknown revision" >&2
                  exit 128
                fi
                if [ -f "#{dir}/pull-ran" ]; then
                  echo "post-pull-sha"
                else
                  echo "pre-pull-sha"
                fi
                ;;
            esac
            ;;
          status)
            if [ "${2:-}" = "--porcelain" ]; then
              printf '%s' "#{dirty_status_output}"
            fi
            exit 0
            ;;
          stash)
            echo "stash: $*" >> "#{dir}/git-stash.log"
            if [ "${2:-}" = "pop" ]; then
              rm -f "#{dir}/pre-existing-stash"
              if [ #{stash_pop_exit_status} -eq 0 ]; then
                rm -f "#{dir}/refs-stash"
              fi
              printf '%s\n' "#{stash_pop_output}"
              exit #{stash_pop_exit_status}
            fi
            printf '%s\n' "#{stash_push_output}"
            if [ #{stash_push_exit_status} -eq 0 ] && [ "#{stash_push_output}" != "No local changes to save" ]; then
              printf '%s\n' "stub-stash-sha" > "#{dir}/refs-stash"
            fi
            exit #{stash_push_exit_status}
            ;;
          checkout)
            exit 0
            ;;
          pull)
            touch "#{dir}/pull-ran"
            printf 'git pull\\n' >> "#{dir}/calls.log"
            exit #{pull_exit_status}
            ;;
          diff)
            cat "#{pull_diff_file}" 2>/dev/null || true
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
        {
          printf 'CMD=%s\n' "$1"
          env | sort | grep -E '^(BUNDLE_GEMFILE|BUNDLE_BIN_PATH|BUNDLER_SETUP|BUNDLER_VERSION|RUBYLIB|RUBYOPT|RUBYGEMS_GEMDEPS)=' || true
          printf '%s\n' '--'
        } >> "#{dir}/stubbin/overmind-env.log"
        case "$1" in
          status)
            if [ #{overmind_status_exit_status} -ne 0 ]; then
              echo "overmind status unavailable" >&2
              exit #{overmind_status_exit_status}
            fi
            [ -e "#{dir}/overmind-running" ]
            running=$?
            if [ "$running" -ne 0 ]; then
              exit "$running"
            fi

            count_file="#{dir}/overmind-status-count"
            count=0
            if [ -f "$count_file" ]; then
              count="$(cat "$count_file")"
            fi
            count=$((count + 1))
            printf '%s' "$count" > "$count_file"

            if [ "#{status_successes_after_start.nil? ? '' : status_successes_after_start}" != "" ] && [ "$count" -gt #{status_successes_after_start || 0} ]; then
              rm -f "#{dir}/overmind-running"
              exit 1
            fi
            if [ "#{overmind_status_malformed ? 1 : 0}" = "1" ]; then
              echo "private malformed status response"
              exit 0
            fi
            echo "PROCESS   PID       STATUS"
            echo "web       12345     running"
            if [ "#{overmind_worker_processes ? 1 : 0}" = "1" ]; then
              echo "worker_poll   12346   running"
              echo "worker_agent  12347   running"
            fi
            exit 0
            ;;
          quit)
            barriers_held=1
            for mode in poll agent; do
              lock="${TMPDIR:-/tmp}/paid-worker-ready-temporal_worker-${mode}.admission.lock"
              exec 8<>"$lock"
              flock -n 8 && barriers_held=0
              exec 8>&-
            done
            if [ "$barriers_held" -eq 1 ]; then
              touch "#{dir}/worker-admission-barriers-held-at-stop"
            fi
            printf 'overmind quit\\n' >> "#{dir}/calls.log"
            touch "#{dir}/overmind-quit-ran"
            rm -f "#{dir}/overmind-running"
            exit 0
            ;;
          restart)
            touch "#{dir}/overmind-restart-ran"
            #{unknown_head_line}
            #{write_worker_readiness_line}
            echo "overmind restarted processes"
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
        socket="$2"
        command="$3"
        format="$6"
        case "$command" in
          list-panes)
            [ -e "#{dir}/tmux-session-stopped" ] && exit 0
            window="web"
            case "#{tmux}" in
              socket_disappeared)
                rm -f "$socket"
                echo "error connecting to $socket (No such file or directory)" >&2
                exit 1
                ;;
              no_server)
                if [ ! -e "#{dir}/dev-ran" ]; then
                  echo "no server running on $2" >&2
                  exit 1
                fi
                path="$PWD"
                ;;
              same_workspace)
                # Model a real orphaned dev supervisor: it still hosts a
                # worker_poll Temporal worker window.
                path="$PWD"
                window="worker_poll"
                ;;
              same_workspace_worker_free|stop_fails) path="$PWD" ;;
              inspection_fails)
                echo "error connecting to $socket (Permission denied)" >&2
                exit 1
                ;;
              other_worktree) path="/other/worktree" ;;
              *) exit 1 ;;
            esac
            if [[ "$format" == *session_name* ]]; then
              printf 'paid|%s\\n' "$path"
            elif [[ "$format" == *window_name* ]]; then
              printf '%s|%s\\n' "$path" "$window"
            else
              printf '%s\\n' "$path"
            fi
            ;;
          kill-session)
            printf 'tmux kill-session %s\\n' "$5" >> "#{dir}/calls.log"
            if [ "#{tmux}" = "stop_fails" ]; then
              echo "tmux stop failed" >&2
              exit 1
            fi
            touch "#{dir}/tmux-session-stopped"
            ;;
          ls)
            [ -e "#{dir}/tmux-session-stopped" ] && exit 0
            echo "paid: 1 windows"
            ;;
          *)
            echo "unexpected tmux command: $*" >&2
            exit 1
            ;;
        esac
      BASH
    )

    script_path
  end

  def create_overmind_tmux_socket(dir)
    socket_dir = File.join(dir, "tmux")
    FileUtils.mkdir_p(socket_dir)
    socket = File.join(socket_dir, "overmind-#{File.basename(dir)}-orphan")
    UNIXServer.open(socket) { |server| server.close }
    socket
  end

  def stale_socket_worker_orphan_env(dir)
    poll_env.merge(
      "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
      "OVERMIND_SOCKET" => ".overmind.sock",
      "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => File.join(dir, "tmux"),
      "DEV_UPDATE_CHANGED_FILES" => "app/services/llm/request.rb"
    )
  end

  def create_stale_socket(dir)
    socket_path = File.join(dir, ".overmind.sock")
    UNIXServer.open(socket_path) { |server| server.close }
    expect(File.socket?(socket_path)).to be(true)
    socket_path
  end

  def with_active_overmind_socket(dir)
    socket_path = File.join(dir, ".overmind.sock")
    server = UNIXServer.new(socket_path)
    yield
  ensure
    server&.close
    FileUtils.rm_f(socket_path)
  end
end
