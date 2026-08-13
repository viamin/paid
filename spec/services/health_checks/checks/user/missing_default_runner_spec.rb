# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::User::MissingDefaultRunner do
  let(:user) { create(:user) }
  let!(:runner) { create(:runner, user: user, runner_key: "cursor") }

  it "returns a finding when the default runner references an unavailable runner" do
    setting = create(:user_setting, user: user, default_agent_runner: runner.routing_key)
    setting.update_columns(default_agent_runner: "ghost_runner")

    expect(described_class.call(user)).to contain_exactly(
      have_attributes(
        code: :missing_default_runner,
        scope: :user,
        severity: :warning,
        title: "Default runner is no longer available",
        remediation: a_string_including("default runner"),
        action_url: "/runners",
        metadata: { default_agent_runner: "ghost_runner" }
      )
    )
  end

  it "returns no findings when the default runner is available" do
    create(:user_setting, user: user, default_agent_runner: runner.routing_key)

    expect(described_class.call(user)).to eq([])
  end

  it "returns no findings when no enabled runners remain (covered by NoAgentRunners)" do
    create(:user_setting, user: user, default_agent_runner: runner.routing_key)
    user.runners.kept_only.for_agent_runs.update_all(enabled_for_agent_runs: false)

    expect(described_class.call(user)).to eq([])
  end
end
