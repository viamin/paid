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

  def configuration_profile_tool_message
    tool_message(
      role: "tool",
      tool_status: nil,
      tool_name: "plan_configuration_profile",
      tool_result: {
        "profile_id" => "solo_automated",
        "project_id" => 42,
        "label" => "Apply Solo Automated posture",
        "source" => "configuration_profile",
        "changes" => [
          { "field" => "auto_pick_enabled", "from" => false, "to" => true }
        ],
        "applied_fields" => [ "auto_pick_enabled" ]
      },
      tool_arguments: nil
    )
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

  it "renders field from/to diffs for configuration profile plans" do
    render partial: "chat_messages/tool_call", locals: { message: configuration_profile_tool_message }

    expect(rendered).to include("Configuration Profile Plan")
    expect(rendered).to include("Solo automated for project #42")
    expect(rendered).to include("Auto-pick issues")
    expect(rendered).to include("From:")
    expect(rendered).to include("To:")
    expect(rendered).not_to include("Prerequisites")
  end
end
