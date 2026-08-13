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

  def completed_log_payload
    hash_including(
      message: "claude_auth.health_check.completed",
      accounts_checked: 1,
      runners_checked: 2,
      invalid_runners: 1,
      expiring_runners: 1,
      accounts_errored: 0
    )
  end

  describe "#perform" do
    it "logs aggregate auth-health counts for configured accounts" do
      target_account = create(:account)
      create(:account)
      health = [
        auth_health_result(valid: false, expires_at: 2.hours.ago, error: "Session expired"),
        auth_health_result(valid: true, expires_at: 2.hours.from_now, error: nil)
      ]

      allow(Runners::AuthHealth).to receive(:call) do |account:, **|
        account.id == target_account.id ? health : []
      end
      allow(Rails.logger).to receive(:info)

      described_class.perform_now

      expect(Runners::AuthHealth).to have_received(:call).with(
        account: target_account,
        host_forwarded_status_by_runner_key: kind_of(Hash)
      )
      expect(Rails.logger).to have_received(:info).with(completed_log_payload)
    end

    it "reuses the same host-forwarded cache across accounts" do
      create_list(:account, 2)
      caches = []
      allow(Runners::AuthHealth).to receive(:call) do |**kwargs|
        caches << kwargs.fetch(:host_forwarded_status_by_runner_key)
        []
      end

      described_class.perform_now

      expected_account_count = Account.count

      expect(Runners::AuthHealth).to have_received(:call).exactly(expected_account_count).times
      expect(caches.size).to eq(expected_account_count)
      expect(caches.map(&:object_id).uniq.size).to eq(1)
    end
  end
end
