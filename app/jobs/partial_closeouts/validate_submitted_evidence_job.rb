# frozen_string_literal: true

module PartialCloseouts
  class ValidateSubmittedEvidenceJob < ApplicationJob
    queue_as :low_priority
    self.perform_timeout = 2.minutes

    discard_on ActiveRecord::RecordNotFound

    # @spec PARTIAL-CLOSEOUT-035
    def perform(notification_id, prerequisite_identity)
      notification = Notification.find(notification_id)
      ValidateSubmittedEvidence.call(notification:, prerequisite_identity:)
    end

    private

    def tenant_account
      Notification.find_by(id: arguments.first)&.account
    end
  end
end
