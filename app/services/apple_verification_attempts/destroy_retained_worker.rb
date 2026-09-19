# frozen_string_literal: true

module AppleVerificationAttempts
  class DestroyRetainedWorker
    def self.call(...) = new(...).call

    def initialize(attempt:)
      @attempt = attempt
    end

    def call
      request_destruction
      attempt.mark_retained_vm_destroyed!
    end

    private

    attr_reader :attempt

    def request_destruction
      return if attempt.temporal_workflow_id.blank?

      Paid.temporal_client.workflow_handle(attempt.temporal_workflow_id).signal("destroy_retained_worker")
    rescue Temporalio::Error::RPCError => e
      raise unless e.code == Temporalio::Error::RPCError::Code::NOT_FOUND
    end
  end
end
