# frozen_string_literal: true

# Shared helper for stubbing Open3.popen3 in collector specs.
# Simulates Open3.popen3 yielding a completed process with given stdout/stderr/status.
# Accepts either an argv array (exact match) or a Regexp to match against the full argument list.
module Popen3Stub
  def stub_popen3(command_pattern, stdout:, stderr: "", success: true, exit_code: 0)
    status = instance_double(Process::Status, success?: success, exitstatus: exit_code)
    wait_thr = instance_double(Thread, pid: 12345, value: status)
    stdin_io = instance_double(IO, close: nil)
    stdout_io = instance_double(IO, "read": stdout, closed?: false, close: nil)
    stderr_io = instance_double(IO, "read": stderr, closed?: false, close: nil)

    if command_pattern.is_a?(Regexp)
      allow(Open3).to receive(:popen3) do |*args, **_kwargs, &block|
        if args.join(" ").match?(command_pattern)
          block.call(stdin_io, stdout_io, stderr_io, wait_thr)
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
end
