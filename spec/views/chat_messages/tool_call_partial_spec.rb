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
      role: "assistant",
      tool_status: "pending",
      tool_name: "apply_configuration_profile",
      tool_arguments: {
        "profile_id" => "solo_fully_automated",
        "plan" => {
          "profile_id" => "solo_fully_automated",
          "project_id" => 42,
          "changes" => [
            {
              "level" => "user",
              "attribute" => "user_settings.run_concurrency_mode",
              "before" => "manual",
              "after" => "auto"
            }
          ],
          "prerequisites" => [
            { "key" => "github_app_installed", "description" => "GitHub App must be installed" }
          ]
        }
      },
      tool_result: nil
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

  it "renders grouped before/after diffs for configuration profile plans" do
    render partial: "chat_messages/tool_call", locals: { message: configuration_profile_tool_message }

    expect(rendered).to include("Configuration Profile Plan")
    expect(rendered).to include("Solo fully automated for project #42")
    expect(rendered).to include("Before:")
    expect(rendered).to include("manual")
    expect(rendered).to include("After:")
    expect(rendered).to include("auto")
    expect(rendered).to include("GitHub App must be installed")
  end
end
