# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ChatContext do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:, labels: [ "bug", "paid:needs-input" ]) }
  let(:chat_session) do
    create(
      :chat_session,
      account:,
      project:,
      created_by: user,
      inbox_item_key: "clarifying_questions:#{issue.id}",
      inbox_item_metadata: { "kind" => "clarifying_questions", "issue_id" => issue.id }
    )
  end

  it "loads only explicitly requested sections without changing the system prompt" do
    # @spec QUESTION-EXPLORATION-014
    context = described_class.call(chat_session:, user:, sections: %i[labels queue_metadata])

    expect(context).to eq(
      "labels" => [ "bug", "paid:needs-input" ],
      "queue_metadata" => { "kind" => "clarifying_questions", "issue_id" => issue.id }
    )
    expect(chat_session.messages).to be_empty
  end

  it "rejects context access after comment permission is removed" do
    # @spec QUESTION-EXPLORATION-014
    user.remove_role(:owner, account)

    expect { described_class.call(chat_session:, user:, sections: [ :labels ]) }
      .to raise_error(Pundit::NotAuthorizedError)
  end
end
