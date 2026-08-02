# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::User::InvalidFallbackChain do
  let(:user) { create(:user) }
  let!(:runner) { create(:runner, user: user, runner_key: "cursor") }

  it "returns a finding when the fallback chain references unavailable runners" do
    setting = create(:user_setting, user: user, fallback_runners: [ runner.routing_key ])
    setting.update_columns(fallback_runners: [ runner.routing_key, "ghost" ])

    expect(described_class.call(user)).to contain_exactly(
      have_attributes(
        code: :invalid_fallback_chain,
        scope: :user,
        severity: :warning,
        title: "Fallback runner chain references unavailable runners",
        description: a_string_including("ghost"),
        remediation: a_string_including("fallback chain"),
        action_url: "/runners",
        metadata: { stale_fallback_runners: [ "ghost" ] }
      )
    )
  end

  it "returns no findings when the fallback chain resolves cleanly" do
    create(:user_setting, user: user, fallback_runners: [ runner.routing_key ])

    expect(described_class.call(user)).to eq([])
  end

  it "returns no findings when no fallback chain is configured" do
    create(:user_setting, user: user)

    expect(described_class.call(user)).to eq([])
  end
end
