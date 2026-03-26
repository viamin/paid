# frozen_string_literal: true

require "open3"

# Shared helper for stubbing Open3.popen3 in collector specs.
# Simulates Open3.popen3 yielding a completed process with given stdout/stderr/status.
# Accepts either an argv array (exact match) or a Regexp to match against the full argument list.
module Popen3Stub
  # Lightweight fake IO that tracks closed state, matching real IO semantics
  # so code paths relying on closed? (e.g., BaseCollector timeout/ensure cleanup)
  # behave correctly.
  class FakeIO
    def initialize(read_content = "")
      @read_content = read_content
      @closed = false
    end

    def read(*_args)
      @read_content
    end

    def close
      @closed = true
      nil
    end

    def closed?
      @closed
    end
  end

  def stub_popen3(command_pattern, stdout:, stderr: "", success: true, exit_code: 0)
    status = instance_double(Process::Status, success?: success, exitstatus: exit_code)
    wait_thr = instance_double(Process::Waiter, pid: 12345, value: status)
    stdin_io = FakeIO.new
    stdout_io = FakeIO.new(stdout)
    stderr_io = FakeIO.new(stderr)

    if command_pattern.is_a?(Regexp)
      allow(Open3).to receive(:popen3).and_wrap_original do |original, *args, **kwargs, &block|
        if args.join(" ").match?(command_pattern)
          block.call(stdin_io, stdout_io, stderr_io, wait_thr)
        else
          original.call(*args, **kwargs, &block)
        end
      end
    else
      allow(Open3).to receive(:popen3).with(*command_pattern, pgroup: true) do |*, &block|
        block.call(stdin_io, stdout_io, stderr_io, wait_thr)
      end
    end
  end
end

RSpec.configure do |config|
  config.include Popen3Stub, type: :service
  config.include Popen3Stub, :no_db
end
