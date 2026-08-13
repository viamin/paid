# frozen_string_literal: true

require "rails_helper"

# @spec CHAT-CONTAINER-PROVISIONING-001
# @spec CHAT-CONTAINER-PROVISIONING-005
RSpec.describe ChatSessions::Create do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe ".call" do
    it "creates an active inline-only session" do
      # @spec CHAT-API-001
      session = described_class.call(account: account, user: user)

      expect(session).to be_persisted
      expect(session.status).to eq("active")
      expect(session.container_capability).to eq("none")
      expect(session.created_by).to eq(user)
      expect(session.account).to eq(account)
      expect(session.idle_timeout_at).to be_within(5.seconds).of(30.minutes.from_now)
    end

    it "persists a system prompt as the first message" do
      # @spec CHAT-API-001
      session = described_class.call(account: account, user: user)

      system_message = session.messages.find_by(role: "system")
      expect(system_message).to be_present
      expect(system_message.content).to include("Paid")
    end

    it "uses a custom system prompt when provided" do
      # @spec CHAT-API-001
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
      runner = create_api_chat_runner
      session = described_class.call(
        account: account,
        user: user,
        runner_id: runner.id,
        model: "gpt-4o"
      )

      expect(session.runner).to eq(runner)
      expect(session.model).to eq("gpt-4o")
    end

    it "defaults to the first configured API-key chat runner" do
      non_chat_runner = user.runners.find_by!(runner_key: "claude")
      non_chat_runner.update!(enabled_for_chat: false)
      create(:runner, user: user, runner_key: "cursor", enabled_for_chat: true)
      chat_runner = create_api_chat_runner

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
      runner = create_api_chat_runner
      session = described_class.call(
        account: account,
        user: user,
        provider_id: runner.id
      )

      expect(session.runner).to eq(runner)
    end

    it "raises when an inline chat runner cannot build an API chat client" do
      runner = create(:runner, user: user, runner_key: "codex", auth_type: "subscription", enabled_for_chat: true)

      expect {
        described_class.call(account: account, user: user, runner_id: runner.id)
      }.to raise_error(ArgumentError, /API-key chat runner/)
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

    it "creates a pending container-backed session" do
      session = described_class.call(account: account, user: user, container_capability: "pending")

      expect(session.container_capability).to eq("pending")
      expect(session.container_requested_at).to be_present
    end

    it "enqueues background provisioning for a pending session" do
      expect {
        described_class.call(account: account, user: user, container_capability: "pending")
      }.to have_enqueued_job(ChatSessions::ProvisionContainerJob)
        .with(hash_including(chat_session_id: kind_of(Integer), account_id: account.id))
    end

    it "returns the session and schedules a recheck when account-scoped provisioning enqueue is saturated" do
      allow(ChatSessions::ProvisionContainerJob).to receive(:perform_later)
        .and_raise(GoodJob::ActiveJobExtensions::Concurrency::ConcurrencyExceededError)
      allow(Rails.logger).to receive(:info).and_call_original

      session = nil
      expect {
        session = described_class.call(account: account, user: user, container_capability: "pending")
      }.to have_enqueued_job(ChatSessions::ReenqueuePendingProvisionJob)
        .with(account_id: account.id)

      expect(session).to be_persisted
      expect(session.container_capability).to eq("pending")
      expect(Rails.logger).to have_received(:info).with(
        hash_including(
          message: "chat_sessions.create.provision_container_job_deferred",
          chat_session_id: session.id,
          account_id: account.id
        )
      )
    end

    it "does not block on provisioning (returns the session immediately)" do
      session = described_class.call(account: account, user: user, container_capability: "pending")

      expect(session).to be_persisted
      expect(session.container_capability).to eq("pending")
    end

    it "does not enqueue provisioning for an inline-only session" do
      expect {
        described_class.call(account: account, user: user)
      }.not_to have_enqueued_job(ChatSessions::ProvisionContainerJob)
    end

    it "defers eager-disabled container requests to the lazy provisioning path" do
      account.tenant_setting!.update!(features: { "chat_settings" => { "chat_eager_provisioning" => false } })

      session = nil
      expect {
        session = described_class.call(account: account, user: user, container_capability: "pending")
      }.not_to have_enqueued_job(ChatSessions::ProvisionContainerJob)

      expect(session.container_capability).to eq("none")
      expect(session.container_requested_at).to be_nil
    end

    it "enqueues background provisioning when eager provisioning is enabled" do
      account.tenant_setting!.update!(features: { "chat_settings" => { "chat_eager_provisioning" => true } })

      expect {
        described_class.call(account: account, user: user, container_capability: "pending")
      }.to have_enqueued_job(ChatSessions::ProvisionContainerJob)
        .with(hash_including(chat_session_id: kind_of(Integer), account_id: account.id))
    end

    it "raises for invalid container capability" do
      expect {
        described_class.call(account: account, user: user, container_capability: "invalid")
      }.to raise_error(ArgumentError, /container_capability/)
    end

    it "rejects lifecycle-only container capabilities at creation time" do
      %w[provisioning ready failed stopped].each do |capability|
        expect {
          described_class.call(account: account, user: user, container_capability: capability)
        }.to raise_error(ArgumentError, /container_capability/)
      end
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

  def create_api_chat_runner
    create(:runner, :api_key, user: user, runner_key: "opencode",
      provider_api_key: create(:provider_api_key, user: user, api_service_type: "openrouter"),
      config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2" } })
  end
end
