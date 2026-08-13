# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::SendMessage do
  describe "operator tools workflow" do
  let(:operator_account) { create(:account) }
  let(:target_account) { create(:account) }
  let(:operator) { create(:user, :owner, account: operator_account) }
  let(:chat_session) { create(:chat_session, account: operator_account, created_by: operator) }
  let(:llm_client) do
    Class.new do
      def initialize(responses)
        @responses = responses
      end

      def call(_conversation, **)
        @responses.shift
      end
    end.new([
      {
        content: "I'll suspend that account.",
        tool_calls: [
          { id: "call_1", name: "operator_suspend_account", arguments: { "account_id" => target_account.id } }
        ],
        tokens_input: 10,
        tokens_output: 5,
        model: "gpt-4o"
      },
      {
        content: "The account is now suspended.",
        tool_calls: [],
        tokens_input: 8,
        tokens_output: 4,
        model: "gpt-4o"
      }
    ])
  end

  around do |example|
    original_emails = ENV["PAID_OPERATOR_EMAILS"]
    ENV["PAID_OPERATOR_EMAILS"] = operator.email
    example.run
  ensure
    ENV["PAID_OPERATOR_EMAILS"] = original_emails
  end

    it "lets an operator approve and execute an operator console account action through chat" do
      result = described_class.call(
        chat_session:,
        content: "Suspend account #{target_account.id}",
        llm_client:
      )

      expect(result).to be_nil

      pending_tool_call = chat_session.messages.find_by!(tool_status: "pending", tool_name: "operator_suspend_account")
      expect(pending_tool_call.tool_arguments).to eq("account_id" => target_account.id)

      resumed_message = ChatSessions::ResolveToolCall.call(
        chat_session:,
        tool_call_message: pending_tool_call,
        decision: :approve,
        llm_client:
      )

      expect(resumed_message).to have_attributes(role: "assistant", content: "The account is now suspended.")
      expect(target_account.reload).to be_suspended

      tool_result = chat_session.messages.where(role: "tool", tool_name: "operator_suspend_account").order(:id).last
      expect(tool_result.tool_result).to include("status" => "ok")
    end
  end
end
