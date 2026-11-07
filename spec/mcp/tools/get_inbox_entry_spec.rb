# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::GetInboxEntry do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let!(:issues) do
    create_list(:issue, 3, :needs_input, project:, needs_input_questions: [ "What should happen?" ])
  end

  # @spec MCP-INBOX-TOOLS-002 MCP-INBOX-TOOLS-003
  it "returns the REST detail projection for a current ID and a safe result for stale IDs" do
    entry_id = "clarifying_questions:#{issues.first.id}"
    tool = described_class.new(user:, session:)

    result = tool.call(entry_id:)
    expect(result).to include(found: true, entry: include(id: entry_id, questions: [ "What should happen?" ], progress: be_present))
    expect(tool.call(entry_id: "clarifying_questions:999999")).to eq(found: false)

    issues.first.update!(github_state: "closed")
    expect(tool.call(entry_id:)).to eq(found: false)

    other_account = create(:account)
    other_user = create(:user, account: other_account)
    other_session = create(:chat_session, account: other_account, created_by: other_user)
    expect(described_class.new(user: other_user, session: other_session).call(entry_id:)).to eq(found: false)
  end
end
