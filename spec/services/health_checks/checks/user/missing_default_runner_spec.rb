# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::User::MissingDefaultRunner do
  it "returns a warning when the default runner references a disabled or discarded runner" do
    project = create(:project)
    owner = project.effective_owner
    cursor = create(:runner, user: owner, runner_key: "cursor")
    owner.settings.update!(default_agent_runner: cursor.routing_key)
    cursor.update!(enabled_for_agent_runs: false)

    expect(described_class.call(project)).to contain_exactly(
      have_attributes(
        check: described_class.name,
        scope: :user,
        severity: :warning,
        message: "Default agent runner references a disabled or discarded runner: #{cursor.routing_key}."
      )
    )
  end

  it "returns no findings when the default runner is still valid" do
    project = create(:project)

    expect(described_class.call(project)).to eq([])
  end
end
