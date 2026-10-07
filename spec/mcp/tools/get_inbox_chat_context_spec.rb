# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::GetInboxChatContext do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:, title: "Closeout evidence") }
  let(:session) do
    create(:chat_session, account:, project:, created_by: user,
      inbox_item_key: "partial_closeout:#{issue.id}",
      inbox_item_metadata: { "kind" => "partial_closeout", "issue_id" => issue.id })
  end

  it "retrieves only requested Inbox context without mutating the item" do
    # @spec QUESTION-EXPLORATION-017 @spec OPERATOR-INBOX-002I
    expect(described_class.new(user:, session:).call(sections: [ "queue_metadata" ])).to eq(
      "queue_metadata" => { "kind" => "partial_closeout", "issue_id" => issue.id }
    )
    expect(issue.reload).to be_persisted
  end

  it "is not advertised for a non-Inbox chat" do
    # @spec QUESTION-EXPLORATION-017
    session.update!(inbox_item_key: nil)

    expect(described_class).not_to be_available_for_chat(user:, session:)
  end
end
