# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::Project::EmptyAllowlist do
  it "returns a finding when the allowlist is empty" do
    project = build(:project, allowed_github_usernames: [])

    expect(described_class.call(project)).to contain_exactly(
      have_attributes(
        code: :empty_allowlist,
        scope: :project,
        severity: :error,
        title: "Trusted usernames allowlist is empty",
        remediation: a_string_including("trusted GitHub username"),
        action_url: nil
      )
    )
  end

  it "returns no findings when the allowlist is populated" do
    project = build(:project, allowed_github_usernames: [ "viamin" ])

    expect(described_class.call(project)).to eq([])
  end
end
