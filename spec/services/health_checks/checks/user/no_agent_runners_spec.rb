# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::User::NoAgentRunners do
  before do
    allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor])
  end

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

  it "returns a finding when only non-container-executable runners are enabled for agent runs" do
    project = create(:project)
    owner = project.effective_owner
    owner.runners.kept_only.update_all(enabled_for_agent_runs: false)
    create(:runner, user: owner, runner_key: "codex", enabled_for_agent_runs: true)

    expect(described_class.call(project)).to contain_exactly(
      have_attributes(
        check: described_class.name,
        scope: :user,
        severity: :error,
        message: "Effective owner has no enabled runners for agent runs."
      )
    )
  end
end
