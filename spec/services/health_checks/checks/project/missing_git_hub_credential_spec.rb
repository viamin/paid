# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::Project::MissingGitHubCredential do
  it "returns a finding when both GitHub credentials are missing" do
    project = build(:project, github_token: nil, github_installation: nil)

    expect(described_class.call(project)).to contain_exactly(
      have_attributes(
        code: :missing_git_hub_credential,
        scope: :project,
        severity: :error,
        title: "Missing GitHub credentials",
        remediation: a_string_including("GitHub App installation"),
        action_url: nil
      )
    )
  end

  it "returns no findings when a GitHub credential is present" do
    project = build(:project)

    expect(described_class.call(project)).to eq([])
  end
end
