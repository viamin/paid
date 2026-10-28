# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::ReplayGuard do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }

  # @spec CHAT-TURN-RECOVERY-010
  it "does not replay a completed write tool with the same arguments" do
    user_message = create(:chat_message, chat_session:)
    turn = create(:chat_turn, chat_session:, user_message:)
    create(:chat_message, :tool_call, chat_session:, tool_name: "create_issue", tool_call_id: "tool-1",
      tool_arguments: { "title" => "Avoid duplicates" })
    create(:chat_message, :tool, chat_session:, tool_name: "create_issue", tool_call_id: "tool-1",
      tool_result: { "status" => "ok" })

    result = described_class.call(transcript: ChatTurns::Transcript.call(turn)).result_for(
      name: "create_issue", arguments: { "title" => "Avoid duplicates" }
    )

    expect(result).to include(status: "skipped", reason: "already_completed_in_turn")
  end
end
