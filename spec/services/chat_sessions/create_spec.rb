# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::Create do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe ".call" do
    it "creates an active API mode session" do
      session = described_class.call(account: account, user: user)

      expect(session).to be_persisted
      expect(session.status).to eq("active")
      expect(session.mode).to eq("api")
      expect(session.created_by).to eq(user)
      expect(session.account).to eq(account)
      expect(session.idle_timeout_at).to be_within(5.seconds).of(30.minutes.from_now)
    end

    it "persists a system prompt as the first message" do
      session = described_class.call(account: account, user: user)

      system_message = session.messages.find_by(role: "system")
      expect(system_message).to be_present
      expect(system_message.content).to include("Paid")
    end

    it "uses a custom system prompt when provided" do
      session = described_class.call(
        account: account,
        user: user,
        system_prompt: "You are a test bot."
      )

      system_message = session.messages.find_by(role: "system")
      expect(system_message.content).to eq("You are a test bot.")
    end

    it "associates a project as primary when project_id is provided" do
      project = create(:project, account: account)
      session = described_class.call(
        account: account,
        user: user,
        project_id: project.id
      )

      expect(session.project_id).to eq(project.id)
      assoc = session.chat_session_projects.first
      expect(assoc.context_type).to eq("primary")
    end

    it "resolves and associates a provider" do
      provider = create(:provider, user: user)
      session = described_class.call(
        account: account,
        user: user,
        provider_id: provider.id,
        model: "gpt-4o"
      )

      expect(session.provider).to eq(provider)
      expect(session.model).to eq("gpt-4o")
    end

    it "raises when provider belongs to a different account" do
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      provider = create(:provider, user: other_user)

      expect {
        described_class.call(account: account, user: user, provider_id: provider.id)
      }.to raise_error(ArgumentError, /same account/)
    end

    it "creates a workspace mode session" do
      session = described_class.call(account: account, user: user, mode: "workspace")

      expect(session.mode).to eq("workspace")
    end

    it "raises for invalid mode" do
      expect {
        described_class.call(account: account, user: user, mode: "invalid")
      }.to raise_error(ArgumentError, /mode/)
    end

    it "raises when account is nil" do
      expect {
        described_class.call(account: nil, user: user)
      }.to raise_error(ArgumentError, /account/)
    end

    it "raises when user is nil" do
      expect {
        described_class.call(account: account, user: nil)
      }.to raise_error(ArgumentError, /user/)
    end

    it "sets a title when provided" do
      session = described_class.call(account: account, user: user, title: "Debug session")

      expect(session.title).to eq("Debug session")
    end
  end
end
