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
      "DEV_UPDATE_OVERMIND_START_POLL_COUNT" => "3",
      "DEV_UPDATE_OVERMIND_POLL_INTERVAL" => "0.01"
    }
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
      expect(File.read(dev_start_log_path)).to include("bin/dev booted")
    end
  end

  it "passes a startup cleanup grace period to bin/setup during full restart" do
    Dir.mktmpdir("dev-update-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, capture_startup_cleanup_grace_period_in_dev: true)

      env = poll_env.merge(
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "OVERMIND_SOCKET" => ".overmind.sock",
        "DEV_UPDATE_STARTUP_CLEANUP_GRACE_PERIOD" => nil
      )
      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.read(File.join(dir, "setup-env.log"))).to eq("300\n")
      expect(File.read(File.join(dir, "dev-env.log"))).to eq("300\n")
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

  def write_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod("+x", path)
  end

  def read_updater_log(dir)
    File.read(File.join(dir, "log", "dev-update", "dev-update.log"))
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
    capture_port_in_dev: false,
    capture_startup_cleanup_grace_period_in_dev: false
  )
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.mkdir_p(File.join(dir, "bin", "lib"))
    FileUtils.mkdir_p(File.join(dir, "log"))
    FileUtils.mkdir_p(File.join(dir, "stubbin"))

    FileUtils.touch(File.join(dir, "overmind-running")) if start_overmind_running

    script_path = File.join(dir, "bin", "dev-update")
    FileUtils.cp(script_source, script_path)
    FileUtils.chmod("+x", script_path)
    FileUtils.cp(File.expand_path("../../bin/lib/dev_supervisor.sh", __dir__), File.join(dir, "bin", "lib", "dev_supervisor.sh"))

    dev_start_line = dev_starts_overmind ? %(touch "#{dir}/overmind-running") : ""
    capture_port_line = capture_port_in_dev ? %(printf '%s\n' "${PORT:-}" > "#{dir}/dev-port.log") : ""
    capture_startup_cleanup_grace_period_line =
      capture_startup_cleanup_grace_period_in_dev ? %(printf '%s\n' "${STARTUP_CLEANUP_GRACE_PERIOD:-}" > "#{dir}/dev-env.log") : ""

    write_executable(
      File.join(dir, "bin", "setup"),
      <<~BASH
        #!/usr/bin/env bash
        touch "#{dir}/setup-ran"
        printf '%s\n' "${STARTUP_CLEANUP_GRACE_PERIOD:-}" > "#{dir}/setup-env.log"
        exit #{setup_exit_status}
      BASH
    )

    write_executable(
      File.join(dir, "bin", "dev"),
      <<~BASH
        #!/usr/bin/env bash
        touch "#{dir}/dev-ran"
        #{capture_port_line}
        #{capture_startup_cleanup_grace_period_line}
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
        {
          printf 'CMD=%s\n' "$1"
          env | sort | grep -E '^(BUNDLE_GEMFILE|BUNDLE_BIN_PATH|BUNDLER_SETUP|BUNDLER_VERSION|RUBYLIB|RUBYOPT|RUBYGEMS_GEMDEPS)=' || true
          printf '%s\n' '--'
        } >> "#{dir}/stubbin/overmind-env.log"
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
          restart)
            touch "#{dir}/overmind-restart-ran"
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

    script_path
  end

  def create_stale_socket(dir)
    socket_path = File.join(dir, ".overmind.sock")
    UNIXServer.open(socket_path) { |server| server.close }
    expect(File.socket?(socket_path)).to be(true)
    socket_path
  end
end
