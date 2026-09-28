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

  # @spec OPERATOR-INBOX-002F
  it "reuses a retry-limited investigation chat with a reason-specific title" do
    issue.update!(
      github_number: 4632,
      runner_retry_abandoned_at: Time.current,
      runner_retry_abandon_reason: "All available runners reached the per-issue retry cap (3)."
    )
    retry_entry = Inbox::Queue.call(user:, project:, kind: Inbox::Queue::RETRY_LIMITED_KIND).sole

    first = described_class.call(user:, entry: retry_entry)
    second = described_class.call(user:, entry: retry_entry)

    expect(second).to eq(first)
    expect(first).to have_attributes(
      inbox_item_key: "retry_limited:#{issue.id}",
      title: "#{project.full_name}#4632: retry exhaustion chat"
    )
    expect(first.inbox_item_metadata).to include("issue_id" => issue.id)
  end

  # @spec OPERATOR-INBOX-002F
  it "titles a push-blocked investigation chat with its reason" do
    issue.update!(
      runner_retry_abandoned_at: Time.current,
      runner_retry_abandon_reason: "#{Issue::PUSH_PERMISSION_ABANDON_PREFIX} missing workflows permission"
    )
    retry_entry = Inbox::Queue.call(user:, project:, kind: Inbox::Queue::RETRY_LIMITED_KIND).sole

    chat = described_class.call(user:, entry: retry_entry)

    expect(chat.title).to eq("#{project.full_name}##{issue.github_number}: push blocked chat")
  end
end
