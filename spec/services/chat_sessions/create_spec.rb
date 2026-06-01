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

      expect(session.project).to eq(project)
    end

    it "resolves and associates a runner" do
      runner = create(:runner, user: user)
      session = described_class.call(
        account: account,
        user: user,
        runner_id: runner.id,
        model: "gpt-4o"
      )

      expect(session.runner).to eq(runner)
      expect(session.model).to eq("gpt-4o")
    end

    it "defaults to the first chat-eligible runner" do
      non_chat_runner = user.runners.find_by!(runner_key: "claude")
      non_chat_runner.update!(enabled_for_chat: false)
      chat_runner = create(:runner, user: user, runner_key: "cursor", enabled_for_chat: true)

      session = described_class.call(account: account, user: user)

      expect(session.runner).to eq(chat_runner)
      expect(session.runner).not_to eq(non_chat_runner)
    end

    it "prefers a configured API-key runner when one is available" do
      default_runner = user.runners.find_by!(runner_key: "claude")
      api_key_record = create(:provider_api_key, user: user, api_key: "sk-openrouter-test", api_service_type: "openrouter")
      configured_runner = create(:runner, :api_key,
        user: user,
        runner_key: "opencode",
        provider_api_key: api_key_record,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2" } }
      )

      session = described_class.call(account: account, user: user)

      expect(session.runner).to eq(configured_runner)
      expect(session.runner).not_to eq(default_runner)
    end

    it "accepts provider_id as a legacy alias for runner_id" do
      runner = create(:runner, user: user)
      session = described_class.call(
        account: account,
        user: user,
        provider_id: runner.id
      )

      expect(session.runner).to eq(runner)
    end

    it "raises when runner belongs to a different account" do
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      runner = create(:runner, user: other_user)

      expect {
        described_class.call(account: account, user: user, runner_id: runner.id)
      }.to raise_error(ArgumentError, /same account/)
    end

    it "raises when the selected runner is not enabled for chat" do
      runner = create(:runner, user: user, enabled_for_chat: false)

      expect {
        described_class.call(account: account, user: user, runner_id: runner.id)
      }.to raise_error(ArgumentError, /enabled for chat/)
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

    it "persists popup page context metadata when provided" do
      session = described_class.call(
        account: account,
        user: user,
        metadata: {
          "entry_point" => "popup",
          "page_context" => {
            "url" => "https://paid.example.test/projects/42",
            "page_title" => "Acme API - Projects - Paid",
            "project_name" => "Acme API"
          }
        }
      )

      expect(session.metadata).to include(
        "entry_point" => "popup",
        "page_context" => include(
          "url" => "https://paid.example.test/projects/42",
          "project_name" => "Acme API"
        )
      )
    end
  end
end
