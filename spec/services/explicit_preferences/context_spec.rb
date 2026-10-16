# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExplicitPreferences::Context do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: owner) }

  # @spec FACET-CONFIDENCE-007
  it "uses confirmed matching scope without promoting contextual answers" do
    user_preference = create(:explicit_preference, account:, user: owner, recorded_by: owner)
    project_preference = create(:explicit_preference, account:, user: owner, recorded_by: owner,
      scope: "project", project:)
    other_preference = create(:explicit_preference, account:, user: owner, recorded_by: owner,
      scope: "project", project: create(:project, account:))

    preferences = described_class.call(owner:, project:)

    expect(preferences).to contain_exactly(user_preference, project_preference)
    expect(preferences).not_to include(other_preference)
  end
end
