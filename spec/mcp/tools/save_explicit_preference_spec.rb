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
end
