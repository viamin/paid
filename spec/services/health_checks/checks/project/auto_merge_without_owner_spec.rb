# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::Project::AutoMergeWithoutOwner do
  # @spec HEALTH-CHECKS-004
  it "returns a finding when auto-merge is enabled without an owner reviewer" do
    project = build(:project, auto_merge_mode: "all", owner_reviewer_login: nil)

    expect(described_class.call(project)).to contain_exactly(
      have_attributes(
        code: :auto_merge_without_owner,
        scope: :project,
        severity: :error,
        title: "Auto-merge enabled without an owner reviewer",
        remediation: a_string_including("owner reviewer login"),
        action_url: nil
      )
    )
  end

  it "returns no findings when auto-merge has an owner reviewer" do
    project = build(:project, auto_merge_mode: "all", owner_reviewer_login: "viamin")

    expect(described_class.call(project)).to eq([])
  end
end
