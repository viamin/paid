# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClaudeAuthHealthCheckJob do
  def auth_health_result(valid:, expires_at:, error:)
    Runners::AuthHealth::Result.new(
      runner: "Claude",
      runner_key: "claude",
      owner_name: "Runner Owner",
      owner_email: "owner@example.com",
      valid: valid,
      expires_at: expires_at,
      source: :host_forwarded,
      error: error
    )
  end

  describe "#perform" do
    it "logs aggregate auth-health counts for configured accounts" do
      account = create(:account)
      create(:account)
      health = [
        auth_health_result(valid: false, expires_at: 2.hours.ago, error: "Session expired"),
        auth_health_result(valid: true, expires_at: 2.hours.from_now, error: nil)
      ]

      allow(Runners::AuthHealth).to receive(:call).and_return([], health)
      allow(Rails.logger).to receive(:info)

      described_class.perform_now

      expect(Runners::AuthHealth).to have_received(:call).with(account: account)
      expect(Rails.logger).to have_received(:info).with(
        hash_including(
          message: "claude_auth.health_check.completed",
          accounts_checked: 1,
          runners_checked: 2,
          invalid_runners: 1,
          expiring_runners: 1,
          accounts_errored: 0
        )
      )
    end
  end
end
