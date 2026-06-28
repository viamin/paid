# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessionsHelper do
  describe "#chat_session_preview" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:chat_session) { create(:chat_session, account: account, created_by: user) }

    it "memoizes the preview for repeated calls within the request" do
      create(:chat_message, chat_session: chat_session, role: "system", content: "Ignored")
      create(:chat_message, chat_session: chat_session, role: "user", content: "First line\nSecond line")

      queries = []
      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        sql = payload[:sql]
        queries << sql if sql.include?('"chat_messages"') && sql.include?("SELECT")
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        preview = helper.chat_session_preview(chat_session)

        expect(preview).to eq("First line Second line")
        expect(helper.chat_session_preview(chat_session)).to eq(preview)
        expect(helper.chat_session_title(chat_session)).to eq(preview)
      end

      expect(queries.count).to eq(1)
    end

    it "falls back to an untitled label when there is no visible content" do
      create(:chat_message, chat_session: chat_session, role: "system", content: "Ignored")

      expect(helper.chat_session_preview(chat_session)).to eq("Untitled chat")
    end

    it "uses preloaded preview_content without querying chat_messages again" do
      create(:chat_message, chat_session: chat_session, role: "user", content: "Preloaded preview")
      preloaded_session = ChatSession.with_preview_content.find(chat_session.id)

      queries = []
      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        sql = payload[:sql]
        queries << sql if sql.include?('"chat_messages"') && sql.include?("SELECT")
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        expect(helper.chat_session_preview(preloaded_session)).to eq("Preloaded preview")
      end

      expect(queries).to be_empty
    end
  end

  describe "#chat_session_projects" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }

    it "includes linked projects even when project_id is nil" do
      chat_session = create(:chat_session, account: account, created_by: user, project: nil)
      primary_project = create(:project, account: account, created_by: user)
      reference_project = create(:project, account: account, created_by: user)
      create(:chat_session_project, chat_session: chat_session, project: primary_project)
      create(:chat_session_project, chat_session: chat_session, project: reference_project)
      chat_session.reload

      expect(helper.chat_session_projects(chat_session)).to contain_exactly(primary_project, reference_project)
    end
  end

  describe "#chat_tool_summary" do
    it "summarizes grep-style match counts" do
      message = build(:chat_message, :tool,
        tool_name: "grep_repo",
        tool_result: { "total_count" => 81, "matches" => [ { "path" => "app.rb" } ] })

      expect(helper.chat_tool_summary(message)).to eq("grep_repo · result · 81 matches")
    end

    it "summarizes list-style result arrays" do
      message = build(:chat_message, :tool,
        tool_name: "list_projects",
        tool_result: [ { "name" => "paid" }, { "name" => "mutant" } ])

      expect(helper.chat_tool_summary(message)).to eq("list_projects · result · 2 items")
    end

    it "summarizes tool errors without expanding the full payload" do
      message = build(:chat_message, :tool,
        tool_name: "search_code",
        tool_result: { error: "internal_error", message: "key not found: :project_id" })

      expect(helper.chat_tool_summary(message)).to eq("search_code · result · error: key not found: :project_id")
    end

    it "expands only pending tool confirmations by default" do
      completed = build(:chat_message, :tool)
      pending = build(:chat_message, :tool_call, tool_status: "pending")

      expect(helper.chat_tool_expanded_by_default?(completed)).to be(false)
      expect(helper.chat_tool_expanded_by_default?(pending)).to be(true)
    end
  end
end
