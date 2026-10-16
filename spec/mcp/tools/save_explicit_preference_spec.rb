# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::SaveExplicitPreference do
  let(:account) { create(:account) }
  let(:user) { create(:user, :admin, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }

  # @spec FACET-CONFIDENCE-007
  it "saves, inspects, corrects, and deletes only the current user's confirmed preference" do
    saved = described_class.new(user:, session:).call(
      statement: "I prefer concise responses.", scope: "user", confirmed: true
    )

    listed = Tools::ListExplicitPreferences.new(user:, session:).call
    corrected = described_class.new(user:, session:).call(
      preference_id: saved.fetch("id"), statement: "I prefer detailed responses.", scope: "user", confirmed: true
    )
    deleted = Tools::DeleteExplicitPreference.new(user:, session:).call(
      preference_id: saved.fetch("id"), confirmed: true
    )

    expect(listed).to include(hash_including("id" => saved.fetch("id"), "statement" => "I prefer concise responses."))
    expect(corrected).to include("statement" => "I prefer detailed responses.")
    expect(deleted).to eq(deleted: true, preference_id: saved.fetch("id"))
    expect(user.explicit_preferences).to be_empty
  end

  it "requires confirmation before writing or deleting a preference" do
    tool = described_class.new(user:, session:)

    expect {
      tool.call(statement: "I prefer concise responses.", scope: "user", confirmed: false)
    }.to raise_error(ArgumentError, /Confirmation required/)
  end

  # @spec FACET-CONFIDENCE-007
  it "lists every preference owned by the user, including preferences outside the current work context" do
    project = create(:project, account:, created_by: user)
    feature_intent = create(:feature_intent, project:)
    preferences = [
      create(:explicit_preference, account:, user:, recorded_by: user),
      create(:explicit_preference, account:, user:, recorded_by: user, scope: "project", project:),
      create(:explicit_preference, account:, user:, recorded_by: user, scope: "feature", project:, feature_intent:)
    ]

    listed = Tools::ListExplicitPreferences.new(user:, session:).call

    expect(listed.pluck("id")).to match_array(preferences.pluck(:id))
  end

  # @spec FACET-CONFIDENCE-007
  it "replaces a corrected preference's confirmed scope and target" do
    project = create(:project, account:, created_by: user)
    preference = create(:explicit_preference, account:, user:, recorded_by: user)

    corrected = described_class.new(user:, session:).call(
      preference_id: preference.id,
      statement: "Use detailed responses for this project.",
      scope: "project",
      project_id: project.id,
      confirmed: true
    )

    expect(corrected).to include("scope" => "project", "project_id" => project.id, "feature_intent_id" => nil)

    reverted = described_class.new(user:, session:).call(
      preference_id: preference.id,
      statement: "Use detailed responses everywhere.",
      scope: "user",
      confirmed: true
    )

    expect(reverted).to include("scope" => "user", "project_id" => nil, "feature_intent_id" => nil)
  end

  # @spec FACET-CONFIDENCE-007
  it "requires project authorization before deleting a project-scoped preference" do
    member = create(:user, :member, account:)
    project = create(:project, account:, created_by: user)
    preference = create(:explicit_preference, account:, user: member, recorded_by: member, scope: "project", project:)
    member_session = create(:chat_session, account:, created_by: member)

    expect {
      Tools::DeleteExplicitPreference.new(user: member, session: member_session).call(preference_id: preference.id, confirmed: true)
    }.to raise_error(Pundit::NotAuthorizedError)
  end
end
