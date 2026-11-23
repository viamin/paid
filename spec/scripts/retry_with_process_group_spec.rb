# frozen_string_literal: true

require "rails_helper"
require "open3"
require "shellwords"

class RetryWithProcessGroup < Pathname
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
    expect(script_source).to include('sleep "$((attempt * backoff_seconds))"')
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
  it "cancels a cooperative descendant with TERM alone, without waiting out the termination grace" do
    child_pid_file = Rails.root.join("tmp/retry-with-process-group-cancelled-cooperative-child.pid")
    FileUtils.rm_f(child_pid_file)
    long_attempt_generous_grace = fast_supervision.merge(
      "DEPENDENCY_SETUP_TIMEOUT" => "60s", "DEPENDENCY_SETUP_TERMINATION_GRACE" => "5s"
    )

    wrapper_pid = Process.spawn(
      long_attempt_generous_grace, script_path, "bash", "-c", "echo $$ > '#{child_pid_file}'; exec sleep 60"
    )
    sleep 0.01 until File.exist?(child_pid_file)
    child_pid = Integer(child_pid_file.read)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    Process.kill("TERM", wrapper_pid)
    _pid, status = Process.wait2(wrapper_pid)

    expect(status).not_to be_success
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).to be < 3
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
    sleep 0.01 until File.exist?(child_pid_file)
    child_pid = Integer(child_pid_file.read)

    Process.kill("TERM", wrapper_pid)
    _pid, status = Process.wait2(wrapper_pid)

    expect(status).not_to be_success
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
end
