# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::Project::AutoMergeWithoutOwner do
  it "returns a finding when auto-merge is enabled without an owner reviewer" do
    project = build(:project, auto_merge_mode: "all", owner_reviewer_login: nil)

    expect(described_class.call(project)).to contain_exactly(
      have_attributes(
        check: described_class.name,
        scope: :project,
        severity: :error,
        message: "Auto-merge is enabled but owner reviewer login is blank."
      )
    )
  end

  it "returns no findings when auto-merge has an owner reviewer" do
    project = build(:project, auto_merge_mode: "all", owner_reviewer_login: "viamin")

    expect(described_class.call(project)).to eq([])
  end
end
