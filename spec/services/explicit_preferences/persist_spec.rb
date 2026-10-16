# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExplicitPreferences::Persist do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }

  # @spec FACET-CONFIDENCE-007
  it "persists only a confirmed explicit statement with an explicit scope" do
    preference = described_class.call(
      account:,
      owner: user,
      actor: user,
      statement: "I prefer keyboard shortcuts for this project.",
      scope: "project",
      project:,
      explicit: true,
      scope_confirmed: true
    )

    expect(preference).to have_attributes(
      account:,
      user:,
      recorded_by: user,
      project:,
      scope: "project",
      statement: "I prefer keyboard shortcuts for this project."
    )
  end

  # @spec FACET-CONFIDENCE-007 QUESTION-EXPLORATION-011
  it "rejects an inferred preference or an unclarified scope" do
    args = {
      account:,
      owner: user,
      actor: user,
      statement: "Keyboard shortcuts are useful.",
      scope: "user"
    }

    expect { described_class.call(**args, explicit: false, scope_confirmed: true) }
      .to raise_error(ArgumentError, "An explicit user statement is required")
    expect { described_class.call(**args, explicit: true, scope_confirmed: false) }
      .to raise_error(ArgumentError, "An explicit or clarified scope is required")
  end

  # @spec FACET-CONFIDENCE-007
  it "allows a confirmed correction and deletion without rewriting prior chat evidence" do
    preference = create(:explicit_preference, account:, user:, recorded_by: user)

    ExplicitPreferences::Update.call(
      preference:,
      actor: user,
      statement: "I prefer detailed technical explanations.",
      explicit: true,
      scope_confirmed: true
    )
    ExplicitPreferences::Delete.call(preference:)

    expect(ExplicitPreference).not_to exist(preference.id)
  end
end
