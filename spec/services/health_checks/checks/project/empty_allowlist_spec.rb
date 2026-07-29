# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::Project::EmptyAllowlist do
  it "returns a finding when the allowlist is empty" do
    project = build(:project, allowed_github_usernames: [])

    expect(described_class.call(project)).to contain_exactly(
      have_attributes(
        check: described_class.name,
        scope: :project,
        severity: :error,
        message: "Trusted GitHub usernames allowlist is empty."
      )
    )
  end

  it "returns no findings when the allowlist is populated" do
    project = build(:project, allowed_github_usernames: [ "viamin" ])

    expect(described_class.call(project)).to eq([])
  end
end
