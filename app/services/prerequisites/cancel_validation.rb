# frozen_string_literal: true

module Prerequisites
  # Cancels an active prerequisite validation. Cancellation is cooperative:
  # the executor observes the terminal status between phases, preserves the
  # evidence collected so far, and still runs cleanup — cancellation never
  # leaks the provisioned environment (PREREQ-EVIDENCE-007).
  class CancelValidation
    Result = Struct.new(:validation, :code, :message, keyword_init: true) do
      def success? = code.nil?
    end

    def self.call(...) = new(...).call

    def initialize(validation)
      @validation = validation
    end

    def call
      return failure(:not_active, "Validation ##{validation.id} is already #{validation.status}.") unless validation.active?

      if validation.running?
        validation.update!(status: "cancelled", completed_at: Time.current)
      else
        # Still pending: the executor has not picked it up. Record the
        # terminal status and the skipped checks so the evidence row explains
        # itself; the job discards a cancelled validation without executing.
        validation.complete!(
          status: "cancelled",
          result: { "requested_checks" => %w[native_analyzer], "checks" => {
            "native_analyzer" => { "status" => "skipped", "reason" => "Cancelled before execution started." }
          } }
        )
      end

      Rails.logger.info(
        message: "prerequisites.cancel_validation.cancelled",
        prerequisite_validation_id: validation.id
      )
      Result.new(validation: validation)
    end

    private

    attr_reader :validation

    def failure(code, message)
      Result.new(code: code, message: message)
    end
  end
end
