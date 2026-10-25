# frozen_string_literal: true

module PrerequisiteExecutions
  # Operator cancellation of an active validation attempt: preserves the
  # steps already collected, runs the shared cleanup, cancels the paired
  # synthetic run, and records the terminal outcome.
  #
  # @spec PREREQ-EXEC-013
  class Cancel
    Result = Data.define(:validation, :outcome, :message)

    def self.call(validation)
      new(validation).call
    end

    def initialize(validation)
      @validation = validation
    end

    def call
      return Result.new(validation, :already_terminal,
        "Only an active validation can be cancelled.") unless claim!

      cleanup!
      cancel_agent_run!
      Result.new(validation.reload, :cancelled,
        "Validation cancelled. Evidence collected before cancellation is preserved.")
    end

    private

    attr_reader :validation

    def claim!
      validation.with_lock do
        validation.reload
        return false unless validation.active?

        validation.update!(status: "cancelled", finished_at: Time.current)
      end
      true
    end

    def cleanup!
      Cleanup.call(validation)
    end

    def cancel_agent_run!
      run = validation.agent_run
      return if run.nil? || run.finished?

      run.update!(status: "cancelled", completed_at: Time.current)
    end
  end
end
