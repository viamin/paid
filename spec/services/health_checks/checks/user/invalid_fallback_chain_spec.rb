# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::User::InvalidFallbackChain do
  it "returns a warning when fallback runners reference disabled or discarded runners" do
    project = create(:project)
    owner = project.effective_owner
    cursor = create(:runner, user: owner, runner_key: "cursor")
    owner.settings.update!(fallback_runners: [ cursor.routing_key ])
    cursor.update!(enabled_for_fallback: false)

    expect(described_class.call(project)).to contain_exactly(
      have_attributes(
        check: described_class.name,
        scope: :user,
        severity: :warning,
        message: "Fallback runner chain references disabled or discarded runners: #{cursor.routing_key}."
      )
    )
  end

  it "returns no findings when fallback runners are still valid" do
    project = create(:project)
    owner = project.effective_owner
    cursor = create(:runner, user: owner, runner_key: "cursor")
    owner.settings.update!(fallback_runners: [ cursor.routing_key ])

    expect(described_class.call(project)).to eq([])
  end
end
