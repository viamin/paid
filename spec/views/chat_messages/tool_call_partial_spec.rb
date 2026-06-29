# frozen_string_literal: true

require "rails_helper"

RSpec.describe "chat_messages/_tool_call", :no_db, type: :view do
  def tool_message(**attrs)
    defaults = {
      role: "tool",
      tool_name: "grep_repo",
      tool_status: nil,
      tool_result: { "total_count" => 3 },
      tool_arguments: nil,
      content: nil
    }

    Struct.new(*defaults.keys, keyword_init: true) do
      def pending_confirmation?
        tool_status == "pending"
      end
    end.new(**defaults.merge(attrs))
  end

  it "collapses completed tool results by default" do
    render partial: "chat_messages/tool_call", locals: { message: tool_message }

    expect(rendered).to include("grep_repo · result · 3 matches")
    expect(rendered).not_to match(/<details[^>]*open/)
  end

  it "keeps pending confirmations open for review" do
    render partial: "chat_messages/tool_call", locals: {
      message: tool_message(
        role: "assistant",
        tool_status: "pending",
        tool_name: "trigger_agent_run",
        tool_arguments: { "issue_id" => 42 },
        tool_result: nil
      )
    }

    expect(rendered).to match(/<details[^>]*open/)
    expect(rendered).to include("Assistant wants to run this action")
  end
end
