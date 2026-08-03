# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::User::NoAgentRunners do
  it "returns a finding when the owner has no runners enabled for agent runs" do
    user = create(:user)
    user.runners.kept_only.for_agent_runs.update_all(enabled_for_agent_runs: false)

    expect(described_class.call(user)).to contain_exactly(
      have_attributes(
        code: :no_agent_runners,
        scope: :user,
        severity: :error,
        title: "No runners enabled for agent runs",
        remediation: a_string_including("Enable at least one runner"),
        action_url: "/runners"
      )
    )
  end

  it "returns no findings when at least one runner is enabled for agent runs" do
    user = create(:user)

    expect(described_class.call(user)).to eq([])
  end
end
