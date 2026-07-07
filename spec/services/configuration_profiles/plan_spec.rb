# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationProfiles::Plan do
  subject(:plan) do
    described_class.new(
      profile_id: "solo_fully_automated",
      project_id: nil,
      changes: changes,
      prerequisites: prerequisites,
      questions: questions
    )
  end

  let(:changes) do
    [
      { level: :user, attribute: "user_settings.run_concurrency_mode", before: "manual", after: "auto" },
      { level: :tenant, attribute: "tenant_settings.max_concurrent_runs", before: 5, after: 10 }
    ]
  end
  let(:prerequisites) { [ { key: "github_app_installed", description: "GitHub App must be installed" } ] }
  let(:questions) { [ { key: "max_concurrent_runs", prompt: "How many?", default: 5 } ] }

  describe "#levels" do
    it "returns the unique levels present in the changes" do
      expect(plan.levels).to eq(%i[user tenant])
    end
  end

  describe "#changes_for" do
    it "filters changes by level, accepting a string or symbol" do
      expect(plan.changes_for(:user)).to eq([ changes.first ])
      expect(plan.changes_for("tenant")).to eq([ changes.last ])
    end

    it "returns an empty array for a level with no changes" do
      expect(plan.changes_for(:project)).to eq([])
    end
  end

  describe "#to_h" do
    it "serializes all plan data, including derived levels" do
      expect(plan.to_h).to eq(
        profile_id: "solo_fully_automated",
        project_id: nil,
        levels: %i[user tenant],
        changes: changes,
        prerequisites: prerequisites,
        questions: questions
      )
    end
  end

  it "is immutable" do
    expect(plan).to be_frozen
    expect(plan.changes).to be_frozen
    expect(plan.prerequisites).to be_frozen
    expect(plan.questions).to be_frozen
  end

  it "stringifies the profile_id" do
    plan = described_class.new(profile_id: :solo_fully_automated, project_id: nil)
    expect(plan.profile_id).to eq("solo_fully_automated")
  end
end
