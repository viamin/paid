# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::User::NoAgentRunners do
  it "returns a finding when the effective owner has no enabled agent-run runners" do
    project = create(:project)
    project.effective_owner.runners.kept_only.update_all(enabled_for_agent_runs: false)

    expect(described_class.call(project)).to contain_exactly(
      have_attributes(
        check: described_class.name,
        scope: :user,
        severity: :error,
        message: "Effective owner has no enabled runners for agent runs."
      )
    )
  end

  it "returns no findings when the effective owner has an enabled agent-run runner" do
    project = create(:project)

    expect(described_class.call(project)).to eq([])
  end
end
