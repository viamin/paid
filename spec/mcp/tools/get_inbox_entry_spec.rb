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

  # @spec LAYERED-VERIFY-015 MCP-INBOX-TOOLS-002 MOBILE-API-008
  it "returns the shared REST detail projection for a layered verification finding" do
    audit = create(:agent_run, project:, goal: "layered_verification_audit",
      external_metadata: { "layered_verification" => { "target_revision" => "audit-revision" } })
    obligation = create(:layered_verification_obligation, project:, external_identity: "PAYMENTS-42",
      external_revision: "source-revision", scope_description: "Keep charge settlement idempotent.")
    result = create(:layered_verification_check_result, obligation:, agent_run: audit,
      obligation_coverage: "contradicted", execution_state: "failed_assertion",
      input_revision: { "intent" => "audit-revision" }, limitations: "Only the patch was observed.",
      cause_signature: "duplicate-settlement")
    finding = create(:layered_verification_finding, project:, obligation:, agent_run: audit,
      source_passages: [ "The spec requires one settlement." ],
      observed_behavior: { "check_results" => [ result.id ], "behavior" => "two settlements were observed" },
      check_limitations: [ "No production traffic." ],
      decision: { "question" => "How should this discrepancy be handled?", "options" => [ "defer" ] })
    entry_id = "layered_verification_finding:#{finding.id}"
    expected = Api::V1::InboxEntrySerializer.render(Inbox::FindEntry.call(user:, entry_id:), user:)

    response = described_class.new(user:, session:).call(entry_id:)

    expect(response).to eq(found: true, entry: expected)
    expect(response.dig(:entry, :obligation, :external_identity)).to eq("PAYMENTS-42")
    expect(response.dig(:entry, :contributing_check_results)).to include(a_hash_including(id: result.id))
  end
end
