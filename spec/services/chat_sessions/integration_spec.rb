# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ChatSessions integration", type: :model do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:llm_response) do
    {
      content: "I can help with that.",
      tool_calls: [],
      tokens_input: 100,
      tokens_output: 50,
      model: "gpt-4o"
    }
  end
  let(:llm_client) { instance_double(Proc, call: llm_response) }

  describe "create -> send -> close lifecycle" do
    it "creates a session with a system message" do
      session = ChatSessions::Create.call(account: account, user: user, title: "Test")

      expect(session).to be_persisted
      expect(session.status).to eq("active")
      expect(session.messages.first.role).to eq("system")
    end

    it "sends messages and adds project context" do
      session = ChatSessions::Create.call(account: account, user: user)

      assistant_msg = ChatSessions::SendMessage.call(
        chat_session: session, content: "Hello", llm_client: llm_client
      )
      expect(assistant_msg.role).to eq("assistant")

      project = create(:project, account: account)
      assoc = ChatSessions::AddProjectContext.call(chat_session: session, project: project)
      expect(assoc).to be_persisted

      ChatSessions::SendMessage.call(
        chat_session: session, content: "Follow-up", llm_client: llm_client
      )
      expect(session.messages.where(role: "user").count).to eq(2)
    end

    it "closes session with computed totals" do
      session = ChatSessions::Create.call(account: account, user: user)
      ChatSessions::SendMessage.call(
        chat_session: session, content: "Hello", llm_client: llm_client
      )

      ChatSessions::Close.call(chat_session: session)

      session.reload
      expect(session.status).to eq("closed")
      expect(session.metadata).to include("total_messages", "closed_at")
    end
  end

  it "creates a session with a primary project" do
    project = create(:project, account: account)

    session = ChatSessions::Create.call(account: account, user: user, project_id: project.id)

    expect(session.project).to eq(project)
    expect(session.chat_session_projects).to be_empty

    system_msg = session.messages.find_by(role: "system")
    expect(system_msg.content).to include(project.name)
  end
end
