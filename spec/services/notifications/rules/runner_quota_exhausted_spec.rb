# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Rules::RunnerQuotaExhausted do
  let(:user) { create(:user) }
  let(:runner) { user.runners.find_by!(runner_key: "claude", auth_type: "subscription") }

  before do
    runner
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
  end

  it "publishes after 15 minutes of continuous rate limiting" do
    create(:runner_state, user: user, runner_name: runner.state_key,
      rate_limited_until: 30.minutes.from_now, updated_at: 16.minutes.ago)

    expect {
      described_class.call(scope: runner)
    }.to change(Notification, :count).by(1)

    notification = Notification.find_by!(source: "runner_quota_exhausted", subject: runner)
    expect(notification.severity).to eq("warning")
  end

  it "does not publish inside the tolerance window" do
    create(:runner_state, user: user, runner_name: runner.state_key,
      rate_limited_until: 30.minutes.from_now, updated_at: 10.minutes.ago)

    expect {
      described_class.call(scope: runner)
    }.not_to change(Notification, :count)
  end

  it "resolves when the runner clears" do
    state = create(:runner_state, user: user, runner_name: runner.state_key,
      rate_limited_until: 30.minutes.from_now, updated_at: 16.minutes.ago)
    create(:notification, account: user.account, source: "runner_quota_exhausted", subject: runner)
    state.update!(rate_limited_until: 1.minute.ago)

    described_class.call(scope: runner)

    expect(Notification.find_by!(source: "runner_quota_exhausted", subject: runner).resolved_at).to be_present
  end

  it "deduplicates by runner" do
    create(:runner_state, user: user, runner_name: runner.state_key,
      rate_limited_until: 30.minutes.from_now, updated_at: 16.minutes.ago)

    2.times { described_class.call(scope: runner) }

    expect(Notification.where(source: "runner_quota_exhausted", subject: runner).count).to eq(1)
  end
end
