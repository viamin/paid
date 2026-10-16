# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExplicitPreference do
  subject(:preference) { build(:explicit_preference) }

  it "is valid with an explicit user-scoped statement" do
    expect(preference).to be_valid
  end

  it "requires a project for project-scoped preferences" do
    preference.scope = "project"
    preference.project = nil

    expect(preference).to be_invalid
    expect(preference.errors[:project]).to include("must be present for project scope")
  end

  it "requires a feature intent for feature-scoped preferences" do
    preference.scope = "feature"
    preference.feature_intent = nil

    expect(preference).to be_invalid
    expect(preference.errors[:feature_intent]).to include("must be present for feature scope")
  end

  it "rejects a scope target from another account" do
    preference.project = create(:project)

    expect(preference).to be_invalid
    expect(preference.errors[:project]).to include("must belong to the preference account")
  end
end
