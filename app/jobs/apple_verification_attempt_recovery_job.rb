# frozen_string_literal: true

# Reconciles Apple VM crash windows and ends attempts that exceed their limit.
# @spec APPLE-ATTEMPT-004
# @spec APPLE-ATTEMPT-014
class AppleVerificationAttemptRecoveryJob < ApplicationJob
  queue_as :default

  def perform
    AppleVerificationAttempts::Recovery.call
  end
end
