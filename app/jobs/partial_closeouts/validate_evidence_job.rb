# frozen_string_literal: true

module PartialCloseouts
  # Runs URL retrieval and semantic validation outside the operator request.
  # @spec PARTIAL-CLOSEOUT-033
  class ValidateEvidenceJob < ApplicationJob
    queue_as :default

    discard_on ActiveRecord::RecordNotFound

    def perform(notification_id, prerequisite_identity, evidence_url, explanation)
      AssessEvidence.call(notification: Notification.find(notification_id), prerequisite_identity:, evidence_url:, explanation:)
    end

    private

    def tenant_account
      TenantContext.with_system_access { Notification.find_by(id: arguments.first)&.account }
    end
  end
end
