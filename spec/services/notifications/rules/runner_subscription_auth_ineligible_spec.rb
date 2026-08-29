# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Rules::RunnerSubscriptionAuthIneligible do
  let(:user) { create(:user) }
  let(:runner) { user.runners.find_by!(runner_key: "claude", auth_type: "subscription") }
  let(:project) do
    create(:project, account: user.account, created_by: user, auto_pick_enabled: true, active: true)
  end

  before do
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
  end

  # @spec NOTIFICATION-SEVERITY-011
  it "publishes one blocking notification and inbox entry for an expired managed credential" do
    project
    create(:runner_credential, :expired, runner: runner, runner_user: user)

    expect {
      described_class.call(scope: [ runner ])
    }.to change(Notification, :count).by(1)

    notification = Notification.find_by!(source: "runner_subscription_auth_ineligible", subject: runner)
    expect(notification).to have_attributes(severity: "error", blocking: true, action_url: "/runners/#{runner.id}/edit")
    expect(notification.metadata).to include(expected_runner_notification_metadata("credential_expired"))

    entries = Inbox::Queue.call(user: user, kind: Inbox::Queue::ACTION_REQUIRED_KIND)
    expect(entries.map(&:record)).to include(notification)
  end

  # @spec NOTIFICATION-SEVERITY-011
  it "publishes credential_refresh_failed when the latest refresh attempt failed" do
    credential = create(:runner_credential, runner: runner, runner_user: user, expires_at: 1.hour.from_now)
    create(:runner_auth_attempt, :refresh_failed, project_account: user.account, runner_key: runner.runner_key,
      runner_credential: credential)

    described_class.call(scope: [ runner ])

    notification = Notification.find_by!(source: "runner_subscription_auth_ineligible", subject: runner)
    expect(notification.metadata).to include("reason" => "credential_refresh_failed")
    expect(notification.title).to include("managed credential refresh failed")
  end

  # @spec NOTIFICATION-SEVERITY-011
  it "auto-resolves when the runner is re-authenticated" do
    project
    create(:runner_credential, :expired, runner: runner, runner_user: user)
    described_class.call(scope: [ runner ])
    create(:runner_credential, :long_lived, runner: runner, runner_user: user)

    described_class.call(scope: [ runner ])

    notification = Notification.find_by!(source: "runner_subscription_auth_ineligible", subject: runner)
    expect(notification.resolved_at).to be_present

    entries = Inbox::Queue.call(user: user, kind: Inbox::Queue::ACTION_REQUIRED_KIND)
    expect(entries.map(&:record)).not_to include(notification)
  end

  # @spec NOTIFICATION-SEVERITY-011
  it "does not publish for healthy subscription runners" do
    project
    create(:runner_credential, :long_lived, runner: runner, runner_user: user)

    expect {
      described_class.call(scope: [ runner ])
    }.not_to change(Notification, :count)
  end

  # @spec NOTIFICATION-SEVERITY-011
  it "does not publish for host-forwarded runners without a managed credential" do
    gemini = create(:runner, user: user, runner_key: "gemini", auth_type: "subscription")

    expect {
      described_class.call(scope: [ runner, gemini ])
    }.not_to change(Notification, :count)
  end

  # @spec NOTIFICATION-SEVERITY-011
  it "does not publish for codex without a managed credential (API-key proxy fallback)" do
    codex = create(:runner, user: user, runner_key: "codex", auth_type: "subscription")

    expect {
      described_class.call(scope: [ codex ])
    }.not_to change(Notification, :count)
  end

  # @spec NOTIFICATION-SEVERITY-011
  it "publishes managed_auth_missing when no managed credential or fallback auth path exists" do
    opencode = create(:runner, user: user, runner_key: "opencode", auth_type: "subscription")

    expect {
      described_class.call(scope: [ opencode ])
    }.to change(Notification, :count).by(1)

    notification = Notification.find_by!(source: "runner_subscription_auth_ineligible", subject: opencode)
    expect(notification).to have_attributes(severity: "error", blocking: true)
    expect(notification.metadata).to include(expected_runner_notification_metadata("managed_auth_missing"))
    expect(notification.title).to include("managed credential missing")
  end

  def expected_runner_notification_metadata(reason)
    {
      "reason" => reason,
      "recommended_action" => "Re-authenticate this runner in Runner Settings so future runs can authenticate again.",
      "remediation_steps" => [
        "Open Runner Settings for this runner.",
        "Reconnect or replace the managed credential for the runner.",
        "Retry the blocked run after the runner shows as authenticated."
      ]
    }
  end
end
