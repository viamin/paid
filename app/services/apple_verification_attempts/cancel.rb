# frozen_string_literal: true

module AppleVerificationAttempts
  class Cancel
    def self.call(...) = new(...).call

    def initialize(attempt:)
      @attempt = attempt
    end

    def call
      cancel_workflow
      attempt.mark_cancelled!
    end

    private

    attr_reader :attempt

    def cancel_workflow
      return if attempt.temporal_workflow_id.blank?

      Paid.temporal_client.workflow_handle(attempt.temporal_workflow_id).cancel
    rescue Temporalio::Error::RPCError => e
      raise unless e.code == Temporalio::Error::RPCError::Code::NOT_FOUND
    end
  end
end
