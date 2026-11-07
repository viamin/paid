# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ListInboxEntries do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let!(:issues) do
    create_list(:issue, 3, :needs_input, project:, needs_input_questions: [ "What should happen?" ])
  end

  # @spec MCP-INBOX-TOOLS-001 MCP-INBOX-TOOLS-003
  it "lists a bounded, list-safe actionable projection with cursor pagination" do
    first_page = described_class.new(user:, session:).call(kind: "clarifying_questions", limit: 2)

    expect(first_page.fetch(:entries)).to all(include(kind: "clarifying_questions", summary: be_present))
    expect(first_page.fetch(:entries)).to all(have_key(:action_url))
    expect(first_page.fetch(:entries)).to all(satisfy { |entry| !entry.key?(:progress) && !entry.key?(:history) })
    expect(first_page.fetch(:next_cursor)).to eq(first_page.fetch(:entries).last.fetch(:id))

    second_page = described_class.new(user:, session:).call(
      kind: "clarifying_questions", limit: 2, cursor: first_page.fetch(:next_cursor)
    )
    expect(second_page.fetch(:entries).map { |entry| entry.fetch(:id) }).to eq(
      issues.map { |issue| "clarifying_questions:#{issue.id}" } - first_page.fetch(:entries).map { |entry| entry.fetch(:id) }
    )
    expect(second_page).not_to have_key(:next_cursor)
  end

  # @spec MCP-INBOX-TOOLS-001 MCP-INBOX-TOOLS-003
  it "honors project visibility, actionable defaults, removals, and duplicate reads" do
    other_user = create(:user, account:)
    hidden_project = create(:project, account:, created_by: other_user)
    hidden_issue = create(:issue, :needs_input, project: hidden_project, needs_input_questions: [ "Hidden" ])
    tool = described_class.new(user:, session:)
    entry_id = "clarifying_questions:#{issues.first.id}"

    baseline = tool.call(kind: "clarifying_questions")
    expect(baseline.fetch(:entries).map { |entry| entry.fetch(:id) }).to include(entry_id)
    expect(baseline.fetch(:entries).map { |entry| entry.fetch(:id) }).not_to include("clarifying_questions:#{hidden_issue.id}")
    expect(tool.call(kind: "clarifying_questions")).to eq(baseline)

    entry = Inbox::FindEntry.call(user:, entry_id:)
    Inbox::Removals::Remove.call(entry:, user:)
    expect(tool.call(kind: "clarifying_questions").fetch(:entries).map { |item| item.fetch(:id) }).not_to include(entry_id)
    expect(tool.call(kind: "clarifying_questions", scope: Inbox::Queue::REMOVED_SCOPE)
      .fetch(:entries).map { |item| item.fetch(:id) }).to include(entry_id)
  end

  # @spec MCP-INBOX-TOOLS-002 MCP-INBOX-TOOLS-003
  it "returns the REST detail projection for a current ID and a safe result for stale IDs" do
    entry_id = "clarifying_questions:#{issues.first.id}"
    tool = Tools::GetInboxEntry.new(user:, session:)

    result = tool.call(entry_id:)
    expect(result).to include(found: true, entry: include(id: entry_id, questions: [ "What should happen?" ], progress: be_present))
    expect(tool.call(entry_id: "clarifying_questions:999999")).to eq(found: false)

    issues.first.update!(github_state: "closed")
    expect(tool.call(entry_id:)).to eq(found: false)

    other_account = create(:account)
    other_user = create(:user, account: other_account)
    other_session = create(:chat_session, account: other_account, created_by: other_user)
    expect(Tools::GetInboxEntry.new(user: other_user, session: other_session).call(entry_id:)).to eq(found: false)
  end
end
