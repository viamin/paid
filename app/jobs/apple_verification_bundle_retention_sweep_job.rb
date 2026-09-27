# frozen_string_literal: true

# Deletes Apple verification bundles and VMs after their retention deadlines.
# @spec APPLE-TRANSFER-006
class AppleVerificationBundleRetentionSweepJob < ApplicationJob
  queue_as :maintenance

  def perform
    AppleVerification::Bundles::RetentionSweep.call
  end
end
