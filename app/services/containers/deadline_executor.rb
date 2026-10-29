# frozen_string_literal: true

module Containers
  # Bound a follow-up command without letting the container watchdog destroy
  # the shared run environment. GNU timeout terminates the whole process group.
  class DeadlineExecutor
    def initialize(executor)
      @executor = executor
    end

    delegate :which, :available?, to: :@executor

    def execute(command, timeout: nil, **options) # @spec LLM-ROUTING-006
      return @executor.execute(command, **options) unless timeout

      command = [ "sh", "-c", command ] if command.is_a?(String)
      result = @executor.execute(
        [ "timeout", "--signal=TERM", "--kill-after=5s", "#{timeout}s", *command ],
        timeout: timeout + 10, **options
      )
      raise AgentHarness::TimeoutError, "Isolated text request timed out" if [ 124, 137 ].include?(result.exit_code)

      result
    end
  end
end
