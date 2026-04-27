# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::BuildSystemPrompt do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }

  describe ".call" do
    it "includes base identity" do
      prompt = described_class.call(chat_session: chat_session)

      expect(prompt).to include("Paid")
      expect(prompt).to include("AI development assistant")
    end

    it "includes paid capabilities" do
      prompt = described_class.call(chat_session: chat_session)

      expect(prompt).to include("MCP")
    end

    it "includes primary project context when associated" do
      project = create(:project, account: account, name: "my-app")
      session = create(:chat_session, account: account, created_by: user, project: project)

      prompt = described_class.call(chat_session: session)

      expect(prompt).to include("my-app")
    end

    it "includes reference project context" do
      project = create(:project, account: account, name: "shared-lib")
      chat_session.chat_session_projects.create!(project: project, context_type: "reference")

      prompt = described_class.call(chat_session: chat_session)

      expect(prompt).to include("shared-lib")
    end

    it "includes workspace context for workspace mode" do
      ws_session = create(:chat_session, :workspace, account: account, created_by: user)

      prompt = described_class.call(chat_session: ws_session)

      expect(prompt).to include("Workspace Mode")
    end

    it "omits workspace context for API mode" do
      prompt = described_class.call(chat_session: chat_session)

      expect(prompt).not_to include("Workspace Mode")
    end
  end
end
