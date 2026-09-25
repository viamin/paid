# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::OpenInteractiveChat do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user, auto_pick_enabled: true, active: true) }
  let(:issue) do
    create(:issue, :needs_input, project:, body: "<!-- paid:enhance-issue -->\n\n## Clarifying questions\n1. What changed?\n")
  end
  let(:entry) do
    issue
    Inbox::Queue.call(user:, project:).first
  end

  it "creates and audits the current user's active chat for an inbox item" do
    # @spec QUESTION-EXPLORATION-001
    chat = described_class.call(user:, entry:)

    expect(chat).to have_attributes(
      created_by: user,
      project: project,
      inbox_item_key: entry.id,
      status: "active"
    )
    expect(chat.opened_at).to be_present
    expect(chat.inbox_item_metadata).to include("kind" => entry.kind, "issue_id" => issue.id)
  end

  it "reuses the active chat and creates a replacement after archive" do
    # @spec QUESTION-EXPLORATION-001
    first = described_class.call(user:, entry:)

    expect(described_class.call(user:, entry:)).to eq(first)

    ChatSessions::Archive.call(chat_session: first)

    expect(described_class.call(user:, entry:)).not_to eq(first)
  end

  it "does not allow a viewer to create an inbox chat" do
    # @spec QUESTION-EXPLORATION-007
    viewer = create(:user, :viewer, account:)

    expect { described_class.call(user: viewer, entry:) }.to raise_error(Pundit::NotAuthorizedError)
  end
end
