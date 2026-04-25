# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Rules::ProviderQuotaExhausted do
  let(:user) { create(:user) }
  let(:provider) { user.providers.find_by!(provider_key: "claude", auth_type: "subscription") }

  before do
    provider
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
  end

  it "publishes after 15 minutes of continuous rate limiting" do
    create(:provider_state, user: user, provider_name: provider.state_key,
      rate_limited_until: 30.minutes.from_now, updated_at: 16.minutes.ago)

    expect {
      described_class.call(scope: provider)
    }.to change(Notification, :count).by(1)

    notification = Notification.find_by!(source: "provider_quota_exhausted", subject: provider)
    expect(notification.severity).to eq("warning")
  end

  it "does not publish inside the tolerance window" do
    create(:provider_state, user: user, provider_name: provider.state_key,
      rate_limited_until: 30.minutes.from_now, updated_at: 10.minutes.ago)

    expect {
      described_class.call(scope: provider)
    }.not_to change(Notification, :count)
  end

  it "resolves when the provider clears" do
    state = create(:provider_state, user: user, provider_name: provider.state_key,
      rate_limited_until: 30.minutes.from_now, updated_at: 16.minutes.ago)
    create(:notification, account: user.account, source: "provider_quota_exhausted", subject: provider)
    state.update!(rate_limited_until: 1.minute.ago)

    described_class.call(scope: provider)

    expect(Notification.find_by!(source: "provider_quota_exhausted", subject: provider).resolved_at).to be_present
  end

  it "deduplicates by provider" do
    create(:provider_state, user: user, provider_name: provider.state_key,
      rate_limited_until: 30.minutes.from_now, updated_at: 16.minutes.ago)

    2.times { described_class.call(scope: provider) }

    expect(Notification.where(source: "provider_quota_exhausted", subject: provider).count).to eq(1)
  end
end
