# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationRecoveryJob do
  # @spec APPLE-ATTEMPT-014

  describe "#perform" do
    it "invokes Recovery under system access" do
      result = AppleVerificationAttempts::Recovery::Result.new(reconciled: 1, scanned: 2)
      allow(AppleVerificationAttempts::Recovery).to receive(:call).and_return(result)

      in_system_access = false
      allow(TenantContext).to receive(:with_system_access) do |&block|
        in_system_access = true
        block.call
      end

      described_class.new.perform

      expect(in_system_access).to be(true)
      expect(AppleVerificationAttempts::Recovery).to have_received(:call)
    end

    it "logs a summary when attempts were reconciled or scanned" do
      result = AppleVerificationAttempts::Recovery::Result.new(reconciled: 1, scanned: 2)
      allow(AppleVerificationAttempts::Recovery).to receive(:call).and_return(result)

      logger = instance_double(ActiveSupport::Logger)
      allow(Rails).to receive(:logger).and_return(logger)
      expect(logger).to receive(:info).with(
        hash_including(
          message: "apple_verification_recovery.completed",
          reconciled: 1,
          scanned: 2
        )
      )

      described_class.new.perform
    end

    it "does not log when nothing was reconciled or scanned" do
      result = AppleVerificationAttempts::Recovery::Result.new(reconciled: 0, scanned: 0)
      allow(AppleVerificationAttempts::Recovery).to receive(:call).and_return(result)

      logger = instance_double(ActiveSupport::Logger)
      allow(Rails).to receive(:logger).and_return(logger)
      expect(logger).not_to receive(:info)

      described_class.new.perform
    end
  end
end
