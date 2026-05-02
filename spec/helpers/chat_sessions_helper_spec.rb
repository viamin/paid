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
end
