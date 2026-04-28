# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::AddProjectContext do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:project) { create(:project, account: account) }

  describe ".call" do
    it "creates a chat session project association" do
      expect {
        described_class.call(chat_session: chat_session, project: project)
      }.to change { chat_session.chat_session_projects.count }.by(1)
    end

    it "defaults to reference context type" do
      association = described_class.call(chat_session: chat_session, project: project)

      expect(association.context_type).to eq("reference")
    end

    it "accepts primary context type" do
      association = described_class.call(
        chat_session: chat_session,
        project: project,
        context_type: "primary"
      )

      expect(association.context_type).to eq("primary")
    end

    it "injects a system message with project context" do
      expect {
        described_class.call(chat_session: chat_session, project: project)
      }.to change { chat_session.messages.where(role: "system").count }.by(1)

      context_message = chat_session.messages.where(role: "system").last
      expect(context_message.content).to include(project.name)
    end

    it "raises when session is not active" do
      closed_session = create(:chat_session, :closed, account: account, created_by: user)

      expect {
        described_class.call(chat_session: closed_session, project: project)
      }.to raise_error(ArgumentError, /active/)
    end

    it "raises for invalid context type" do
      expect {
        described_class.call(chat_session: chat_session, project: project, context_type: "invalid")
      }.to raise_error(ArgumentError, /primary or reference/)
    end

    it "raises when project is already associated" do
      chat_session.chat_session_projects.create!(project: project, context_type: "reference")

      expect {
        described_class.call(chat_session: chat_session, project: project)
      }.to raise_error(ArgumentError, /already associated/)
    end
  end
end
