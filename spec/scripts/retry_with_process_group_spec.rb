# frozen_string_literal: true

require "rails_helper"
require "open3"

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
