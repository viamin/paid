# frozen_string_literal: true

require "rails_helper"
require "open3"
require "shellwords"
require "timeout"

class RetryWithProcessGroup < Pathname
end

class RetryExhaustionFixture
  SCRIPT = <<~'BASH'
    #!/usr/bin/env bash
    set -euo pipefail

    attempt=1
    if [[ -f "$RETRY_ATTEMPTS_PATH" ]]; then
      attempt="$(( $(wc -l < "$RETRY_ATTEMPTS_PATH") + 1 ))"
    fi
    printf '%s\n' "$attempt" >> "$RETRY_ATTEMPTS_PATH"
    if [[ -s "$RETRY_CHILD_PIDS_PATH" ]]; then
      previous_child_pid="$(tail -n 1 "$RETRY_CHILD_PIDS_PATH" | cut -d: -f2)"
      previous_child_state="$(ps -o stat= -p "$previous_child_pid" 2>/dev/null || true)"
      if [[ "$previous_child_state" != *Z* && -n "$previous_child_state" ]]; then
        printf 'attempt:%s:overlap:%s\n' "$attempt" "$previous_child_pid" >> "$RETRY_EVENTS_PATH"
        exit 42
      fi
      printf 'attempt:%s:prior-child-gone:%s\n' "$attempt" "$previous_child_pid" >> "$RETRY_EVENTS_PATH"
    fi
    printf 'attempt:%s:leader:%s\n' "$attempt" "$$" >> "$RETRY_EVENTS_PATH"
    trap '' TERM
    (
      printf '%s:%s\n' "$attempt" "$BASHPID" >> "$RETRY_CHILD_PIDS_PATH"
      exec tail -f /dev/null
    ) &
    wait "$!"
  BASH

  def initialize
    @directory = Dir.mktmpdir("retry-with-process-group-retries")
    @fixture_path = File.join(directory, "fail-until-exhausted")
    @attempts_path = File.join(directory, "attempts")
    @events_path = File.join(directory, "events")
    @child_pids_path = File.join(directory, "child-pids")
    File.write(fixture_path, SCRIPT)
    FileUtils.chmod("u+x", fixture_path)
  end

  def run(script_path, environment)
    Open3.capture3(environment.merge(paths), script_path, fixture_path).last
  end

  def attempts
    read(attempts_path)
  end

  def events
    read(events_path)
  end

  def child_pids
    read(child_pids_path)
  end

  def cleanup
    FileUtils.remove_entry(directory)
  end

  private

  attr_reader :attempts_path, :child_pids_path, :directory, :events_path, :fixture_path

  def paths
    {
      "DEPENDENCY_SETUP_MAX_ATTEMPTS" => "3",
      "RETRY_ATTEMPTS_PATH" => attempts_path,
      "RETRY_EVENTS_PATH" => events_path,
      "RETRY_CHILD_PIDS_PATH" => child_pids_path
    }
  end

  def read(path)
    File.readlines(path, chomp: true)
  end
end

RSpec.describe RetryWithProcessGroup, :no_db do
  let(:script_path) { Rails.root.join("bin/retry-with-process-group").to_s }
  let(:fast_supervision) do
    {
      "DEPENDENCY_SETUP_MAX_ATTEMPTS" => "1",
      "DEPENDENCY_SETUP_TIMEOUT" => "0.3s",
      "DEPENDENCY_SETUP_TERMINATION_GRACE" => "0.1s",
      "DEPENDENCY_SETUP_BACKOFF_SECONDS" => "0"
    }
  end

  # @spec TEST-SUITE-023
  it "defaults to five twenty-minute attempts with increasing backoff and a thirty-second termination grace" do
    script_source = File.read(script_path)

    expect(script_source).to include('attempt_limit="${DEPENDENCY_SETUP_MAX_ATTEMPTS:-5}"')
    expect(script_source).to include('attempt_timeout="${DEPENDENCY_SETUP_TIMEOUT:-20m}"')
    expect(script_source).to include('termination_grace="${DEPENDENCY_SETUP_TERMINATION_GRACE:-30s}"')
    expect(script_source).to include('backoff_seconds="${DEPENDENCY_SETUP_BACKOFF_SECONDS:-10}"')
    expect(script_source).to include('wait_for_backoff "$((attempt * backoff_seconds))"')
  end

  # @spec TEST-SUITE-023
  it "returns the successful command status without leaving its child running" do
    child_pid_file = Rails.root.join("tmp/retry-with-process-group-child.pid")
    FileUtils.rm_f(child_pid_file)

    _stdout, _stderr, status = Open3.capture3(
      fast_supervision, script_path, "bash", "-c", "true & child=$!; echo $child > '#{child_pid_file}'; wait $child"
    )

    expect(status).to be_success
    child_pid = Integer(child_pid_file.read)
    expect { Process.kill(0, child_pid) }.to raise_error(Errno::ESRCH)
  ensure
    FileUtils.rm_f(child_pid_file)
  end

  # @spec TEST-SUITE-023
  it "closes its output after a successful command with a long watchdog timer" do
    long_watchdog = fast_supervision.merge("DEPENDENCY_SETUP_TIMEOUT" => "10s")
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    stdout, stderr, status = Open3.capture3(long_watchdog, script_path, "bash", "-c", "true")

    expect(status).to be_success
    expect(stdout).to eq("")
    expect(stderr).to eq("")
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).to be < 3
  end

  # @spec TEST-SUITE-023
  it "reaps the successful cleanup grace timer" do
    with_recording_sleep("30s") do |environment, pid_reader, pid_writer|
      _stdout, _stderr, status = Open3.capture3(
        environment.merge(
          "DEPENDENCY_SETUP_MAX_ATTEMPTS" => "1",
          "DEPENDENCY_SETUP_TERMINATION_GRACE" => "30s"
        ), script_path, "bash", "-c", "true", close_others: false
      )

      timer_pid = read_timer_pid(pid_reader)
      expect(status).to be_success
      expect { Process.kill(0, timer_pid) }.to raise_error(Errno::ESRCH)
    end
  end

  # @spec TEST-SUITE-023
  it "reaps the default first-backoff timer when cancelled" do
    wrapper_pid = nil
    with_recording_sleep("10") do |environment, pid_reader, pid_writer|
      wrapper_pid = spawn_default_backoff_wrapper(environment, pid_writer)
      timer_pid = read_timer_pid(pid_reader)

      Process.kill("TERM", wrapper_pid)
      _pid, status = Process.wait2(wrapper_pid)

      expect(status.termsig).to eq(15)
      expect { Process.kill(0, timer_pid) }.to raise_error(Errno::ESRCH)
    end
  ensure
    begin
      Process.kill("KILL", wrapper_pid) if wrapper_pid
    rescue Errno::ESRCH
      nil
    end
    begin
      Process.wait(wrapper_pid) if wrapper_pid
    rescue Errno::ECHILD
      nil
    end
  end

  # @spec TEST-SUITE-023
  it "stops a watchdog whose process group is not ready when setup succeeds" do
    delayed_setsid_directory = Dir.mktmpdir("retry-with-process-group-setsid")
    delayed_setsid = File.join(delayed_setsid_directory, "setsid")
    File.write(delayed_setsid, <<~BASH)
      #!/usr/bin/env bash
      if [[ "$#" -eq 9 && "$1" == "bash" && "$2" == "-c" ]]; then
        sleep 0.2
      fi
      exec #{Shellwords.escape(`which setsid`.strip)} "$@"
    BASH
    FileUtils.chmod("u+x", delayed_setsid)
    environment = fast_supervision.merge(
      "DEPENDENCY_SETUP_TIMEOUT" => "1s",
      "PATH" => "#{delayed_setsid_directory}:#{ENV.fetch("PATH")}"
    )
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    _stdout, _stderr, status = Open3.capture3(environment, script_path, "bash", "-c", "true")

    expect(status).to be_success
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).to be < 0.8
  ensure
    FileUtils.remove_entry(delayed_setsid_directory) if delayed_setsid_directory
  end

  # @spec TEST-SUITE-023
  it "cancels an owned startup watchdog before it acknowledges its session" do
    with_unacknowledged_watchdog do |wrapper_pid|
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Process.kill("TERM", wrapper_pid)
      _pid, status = Process.wait2(wrapper_pid)

      expect(status.termsig).to eq(15)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).to be < 3
    end
  end

  # @spec TEST-SUITE-023
  it "cancels an owned setup leader before it creates its session" do
    with_unacknowledged_setup_leader do |wrapper_pid, setup_leader_pid|
      Process.kill("TERM", wrapper_pid)
      _pid, status = Process.wait2(wrapper_pid)

      expect(status.termsig).to eq(15)
      expect { Process.kill(0, setup_leader_pid) }.to raise_error(Errno::ESRCH)
    end
  end

  # @spec TEST-SUITE-023
  it "terminates and reaps a cooperative descendant when an attempt times out" do
    child_pid_file = Rails.root.join("tmp/retry-with-process-group-cooperative-child.pid")
    FileUtils.rm_f(child_pid_file)

    _stdout, _stderr, status = Open3.capture3(
      fast_supervision, script_path, "bash", "-c", "echo $$ > '#{child_pid_file}'; exec sleep 60"
    )

    expect(status.exitstatus).to eq(1)
    child_pid = Integer(child_pid_file.read)
    expect { Process.kill(0, child_pid) }.to raise_error(Errno::ESRCH)
  ensure
    FileUtils.rm_f(child_pid_file)
  end

  # @spec TEST-SUITE-023
  it "reaps each timed-out descendant before retrying and exhausts every configured attempt" do
    fixture = RetryExhaustionFixture.new
    status = fixture.run(script_path, fast_supervision.merge("DEPENDENCY_SETUP_TERMINATION_GRACE" => "0.5s"))

    expect(status.exitstatus).to eq(1)
    expect(fixture.attempts).to eq(%w[1 2 3])
    expect(fixture.events).to match([
      /attempt:1:leader:\d+/,
      /attempt:2:prior-child-gone:\d+/,
      /attempt:2:leader:\d+/,
      /attempt:3:prior-child-gone:\d+/,
      /attempt:3:leader:\d+/
    ])
    expect(fixture.child_pids).to match([
      /1:\d+/,
      /2:\d+/,
      /3:\d+/
    ])
  ensure
    fixture&.cleanup
  end

  # @spec TEST-SUITE-023
  it "cancels a cooperative descendant with TERM alone, without waiting out the termination grace" do
    child_pid_file = Rails.root.join("tmp/retry-with-process-group-cancelled-cooperative-child.pid")
    FileUtils.rm_f(child_pid_file)
    long_attempt_generous_grace = fast_supervision.merge(
      "DEPENDENCY_SETUP_TIMEOUT" => "60s", "DEPENDENCY_SETUP_TERMINATION_GRACE" => "5s"
    )

    wrapper_pid = Process.spawn(
      long_attempt_generous_grace, script_path, "bash", "-c", "echo $$ > '#{child_pid_file}'; exec sleep 60"
    )
    wait_for_child_pid_file(child_pid_file)
    child_pid = Integer(child_pid_file.read)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    Process.kill("TERM", wrapper_pid)
    _pid, status = Process.wait2(wrapper_pid)

    expect(status.termsig).to eq(15)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).to be < 3
    expect { Process.kill(0, child_pid) }.to raise_error(Errno::ESRCH)
  ensure
    FileUtils.rm_f(child_pid_file)
  end

  # @spec TEST-SUITE-023
  it "preserves INT when cancelling a cooperative descendant" do
    child_pid_file = Rails.root.join("tmp/retry-with-process-group-cancelled-interrupt-child.pid")
    FileUtils.rm_f(child_pid_file)
    long_attempt = fast_supervision.merge("DEPENDENCY_SETUP_TIMEOUT" => "60s")

    wrapper_pid = Process.spawn(
      long_attempt, script_path, "bash", "-c", "echo $$ > '#{child_pid_file}'; exec sleep 60"
    )
    wait_for_child_pid_file(child_pid_file)
    child_pid = Integer(child_pid_file.read)

    Process.kill("INT", wrapper_pid)
    _pid, status = Process.wait2(wrapper_pid)

    expect(status.termsig).to eq(2)
    expect { Process.kill(0, child_pid) }.to raise_error(Errno::ESRCH)
  ensure
    FileUtils.rm_f(child_pid_file)
  end

  # @spec TEST-SUITE-023
  it "escalates to KILL for a TERM-resistant descendant when the wrapper is cancelled" do
    child_pid_file = Rails.root.join("tmp/retry-with-process-group-cancelled-resistant-child.pid")
    FileUtils.rm_f(child_pid_file)
    long_attempt_fast_grace = fast_supervision.merge("DEPENDENCY_SETUP_TIMEOUT" => "60s")

    wrapper_pid = Process.spawn(
      long_attempt_fast_grace, script_path, "bash", "-c",
      "trap '' TERM; echo $$ > '#{child_pid_file}'; exec tail -f /dev/null"
    )
    wait_for_child_pid_file(child_pid_file)
    child_pid = Integer(child_pid_file.read)

    Process.kill("TERM", wrapper_pid)
    _pid, status = Process.wait2(wrapper_pid)

    expect(status.termsig).to eq(15)
    expect { Process.kill(0, child_pid) }.to raise_error(Errno::ESRCH)
  ensure
    FileUtils.rm_f(child_pid_file)
  end

  # @spec TEST-SUITE-023
  it "terminates and reaps TERM-resistant descendants when an attempt times out" do
    child_pid_file = Rails.root.join("tmp/retry-with-process-group-resistant-child.pid")
    FileUtils.rm_f(child_pid_file)

    _stdout, _stderr, status = Open3.capture3(
      fast_supervision, script_path, "bash", "-c",
      "trap '' TERM; echo $$ > '#{child_pid_file}'; exec tail -f /dev/null"
    )

    expect(status.exitstatus).to eq(1)
    child_pid = Integer(child_pid_file.read)
    expect { Process.kill(0, child_pid) }.to raise_error(Errno::ESRCH)
  ensure
    FileUtils.rm_f(child_pid_file)
  end

  private

  def with_recording_sleep(duration)
    directory = Dir.mktmpdir("retry-with-process-group-timer")
    sleep_path = File.join(directory, "sleep")
    reader, writer = IO.pipe
    writer.close_on_exec = false
    File.write(sleep_path, <<~BASH)
      #!/usr/bin/env bash
      if [[ "$1" == "#{duration}" ]]; then
        printf '%s\\n' "$$" >&"$TIMER_READY_FD"
      fi
      exec /usr/bin/sleep "$@"
    BASH
    FileUtils.chmod("u+x", sleep_path)
    environment = fast_supervision.merge(
      "PATH" => "#{directory}:#{ENV.fetch("PATH")}",
      "TIMER_READY_FD" => writer.fileno.to_s
    )
    yield environment, reader, writer
  ensure
    reader&.close
    writer&.close
    FileUtils.remove_entry(directory) if directory
  end

  def read_timer_pid(reader)
    Integer(Timeout.timeout(2) { reader.gets }.strip)
  end

  def wait_for_child_pid_file(path)
    Timeout.timeout(2, RuntimeError, "Timed out waiting for child PID file: #{path}") do
      sleep 0.01 until File.exist?(path)
    end
  end

  def with_unacknowledged_watchdog
    resources = startup_watchdog_resources
    wrapper_pid = Process.spawn(resources.fetch(:environment), script_path, "bash", "-c", "exec sleep 60", close_others: false)
    Timeout.timeout(2) { resources.fetch(:started_reader).gets }

    yield wrapper_pid
  ensure
    cleanup_startup_watchdog(wrapper_pid, resources)
  end

  def with_unacknowledged_setup_leader
    resources = startup_setup_resources
    wrapper_pid = Process.spawn(resources.fetch(:environment), script_path, "bash", "-c", "exec sleep 60", close_others: false)
    setup_leader_pid = Integer(Timeout.timeout(2) { resources.fetch(:started_reader).gets }.strip)
    resources[:setup_leader_pid] = setup_leader_pid

    yield wrapper_pid, setup_leader_pid
  ensure
    cleanup_startup_watchdog(wrapper_pid, resources)
    terminate_and_reap(resources&.fetch(:setup_leader_pid, nil))
  end

  def startup_watchdog_resources
    directory = Dir.mktmpdir("retry-with-process-group-startup-watchdog")
    started_reader, started_writer = IO.pipe
    gate_reader, gate_writer = IO.pipe
    started_writer.nonblock = false
    gate_reader.nonblock = false
    started_writer.close_on_exec = false
    gate_reader.close_on_exec = false
    delayed_setsid = File.join(directory, "setsid")
    File.write(delayed_setsid, delayed_setsid_script)
    FileUtils.chmod("u+x", delayed_setsid)

    {
      directory: directory,
      environment: startup_watchdog_environment(directory, started_writer, gate_reader),
      gate_reader: gate_reader,
      gate_writer: gate_writer,
      started_reader: started_reader,
      started_writer: started_writer
    }
  end

  def startup_setup_resources
    directory = Dir.mktmpdir("retry-with-process-group-startup-setup")
    started_reader, started_writer = IO.pipe
    gate_reader, gate_writer = IO.pipe
    started_writer.nonblock = false
    gate_reader.nonblock = false
    started_writer.close_on_exec = false
    gate_reader.close_on_exec = false
    delayed_setsid = File.join(directory, "setsid")
    File.write(delayed_setsid, delayed_setup_setsid_script)
    FileUtils.chmod("u+x", delayed_setsid)

    {
      directory: directory,
      environment: fast_supervision.merge(
        "DEPENDENCY_SETUP_TIMEOUT" => "4s",
        "PATH" => "#{directory}:#{ENV.fetch("PATH")}",
        "SETUP_STARTED_FD" => started_writer.fileno.to_s,
        "SETUP_GATE_FD" => gate_reader.fileno.to_s
      ),
      gate_reader: gate_reader,
      gate_writer: gate_writer,
      started_reader: started_reader,
      started_writer: started_writer
    }
  end

  def delayed_setsid_script
    <<~BASH
      #!/usr/bin/env bash
      if [[ "$#" -eq 9 && "$1" == "bash" && "$2" == "-c" ]]; then
        printf '%s\\n' "$$" >&"$WATCHDOG_STARTED_FD"
        read -r _ <&"$WATCHDOG_GATE_FD"
      fi
      exec #{Shellwords.escape(`which setsid`.strip)} "$@"
    BASH
  end

  def delayed_setup_setsid_script
    <<~BASH
      #!/usr/bin/env bash
      if [[ "$#" -eq 3 && "$1" == "bash" && "$2" == "-c" ]]; then
        printf '%s\\n' "$$" >&"$SETUP_STARTED_FD"
        read -r _ <&"$SETUP_GATE_FD"
      fi
      exec #{Shellwords.escape(`which setsid`.strip)} "$@"
    BASH
  end

  def startup_watchdog_environment(directory, started_writer, gate_reader)
    fast_supervision.merge(
      "DEPENDENCY_SETUP_TIMEOUT" => "4s",
      "PATH" => "#{directory}:#{ENV.fetch("PATH")}",
      "WATCHDOG_STARTED_FD" => started_writer.fileno.to_s,
      "WATCHDOG_GATE_FD" => gate_reader.fileno.to_s
    )
  end

  def cleanup_startup_watchdog(wrapper_pid, resources)
    resources&.values_at(:gate_writer, :started_reader, :started_writer, :gate_reader)&.each(&:close)
    terminate_and_reap(wrapper_pid)
    FileUtils.remove_entry(resources.fetch(:directory)) if resources
  end

  def terminate_and_reap(pid)
    Process.kill("KILL", pid) if pid
  rescue Errno::ESRCH
    nil
  ensure
    reap(pid)
  end

  def reap(pid)
    Process.wait(pid) if pid
  rescue Errno::ECHILD
    nil
  end

  def spawn_default_backoff_wrapper(environment, pid_writer)
    Process.spawn(
      environment.merge(
        "DEPENDENCY_SETUP_MAX_ATTEMPTS" => "5",
        "DEPENDENCY_SETUP_TIMEOUT" => "10s",
        "DEPENDENCY_SETUP_TERMINATION_GRACE" => "0.1s",
        "DEPENDENCY_SETUP_BACKOFF_SECONDS" => "10"
      ), script_path, "bash", "-c", "exit 7", pid_writer.fileno => pid_writer, close_others: false
    )
  end
end
