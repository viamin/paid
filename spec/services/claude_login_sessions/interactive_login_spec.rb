# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClaudeLoginSessions::InteractiveLogin do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:session_record) { create(:claude_login_session, account: account, created_by: user) }
  let(:backend) { instance_double(Containers::Backends::LocalDocker) }
  let(:coordination) { instance_double(ClaudeLoginSessions::Coordination, clear!: true) }

  before do
    allow(ClaudeLoginSessions::Coordination).to receive(:new).with(session: session_record).and_return(coordination)
  end

  describe "#consume_output" do
    it "detects an OAuth URL split across PTY chunks" do
      service = described_class.new(session: session_record, backend: backend)

      service.send(:consume_output, "Open this URL: https://claude.")
      service.send(:consume_output, "com/cai/oauth/authorize?code=true")

      expect(session_record.reload.oauth_url).to eq("https://claude.com/cai/oauth/authorize?code=true")
      expect(session_record.status).to eq("awaiting_code")
    end
  end

  describe "#cleanup" do
    it "closes any open login IO handles" do
      service = described_class.new(session: session_record, backend: backend)
      input_reader, input_writer = IO.pipe

      service.instance_variable_set(:@reader, input_reader)
      service.instance_variable_set(:@writer, input_writer)

      service.cleanup

      expect(input_reader).to be_closed
      expect(input_writer).to be_closed
    end
  end

  describe "#run_login_exec!" do
    it "streams the login through the backend instead of shelling out to docker" do
      context = build_login_exec_context(session_record: session_record, backend: backend)

      expect(context[:service].send(:run_login_exec!)).to eq(0)
      expect(context[:observed][:container]).to eq(context[:container])
      expect(context[:observed][:command]).to eq([ "sh", "-lc", "mkdir -p /home/agent/.claude-session && claude auth login" ])
      expect(context[:observed][:options]).to include(
        user: "agent",
        tty: true,
        stdin: context[:input_reader],
        "Env" => [ "HOME=/home/agent", "CLAUDE_CONFIG_DIR=/home/agent/.claude-session" ]
      )
    ensure
      close_pipe_context(context)
    end

    it "relays streamed oauth output back into the session state" do
      context = build_login_exec_context(session_record: session_record, backend: backend)

      context[:service].send(:run_login_exec!)

      expect(session_record.reload.oauth_url).to eq("https://claude.ai/device")
    ensure
      close_pipe_context(context)
    end
  end

  describe "#persist_captured_credentials!" do
    let(:service) { described_class.new(session: session_record, backend: backend) }
    let(:credentials_json) do
      {
        "claudeAiOauth" => {
          "accessToken" => "access-token",
          "refreshToken" => "refresh-token",
          "expiresAt" => 30.days.from_now.iso8601,
          "scopes" => [ "user:inference" ],
          "subscriptionType" => "max"
        }
      }.to_json
    end

    it "reactivates a revoked credential with the same name" do
      revoked_credential = create(
        :integration_credential,
        account: account,
        created_by: user,
        service_key: "claude",
        auth_kind: "oauth_token",
        name: session_record.credential_name,
        revoked_at: 1.day.ago
      )

      service.send(:persist_captured_credentials!, credentials_json)

      expect(revoked_credential.reload.revoked_at).to be_nil
      expect(IntegrationCredential.active).to include(revoked_credential)
      expect(revoked_credential.secret).to eq(credentials_json)
      expect(revoked_credential.expires_at).to be_nil
      expect(revoked_credential.metadata["access_token_expires_at"]).to be_present
      expect(session_record.reload.integration_credential).to eq(revoked_credential)
      expect(session_record.status).to eq("completed")
    end

    it "reuses an existing Claude OAuth credential with the requested name" do
      existing_credential = create(
        :integration_credential,
        account: account,
        created_by: user,
        service_key: "claude",
        auth_kind: "oauth_token",
        name: session_record.credential_name
      )

      service.send(:persist_captured_credentials!, credentials_json)

      expect(IntegrationCredential.where(account: account, service_key: "claude", auth_kind: "oauth_token").count).to eq(1)
      expect(existing_credential.reload.secret).to eq(credentials_json)
      expect(existing_credential.expires_at).to be_nil
      expect(existing_credential.metadata["access_token_expires_at"]).to be_present
      expect(session_record.reload.integration_credential).to eq(existing_credential)
      expect(session_record.status).to eq("completed")
    end

    it "creates a new Claude OAuth credential instead of renaming a different one" do
      existing_credential = create(
        :integration_credential,
        account: account,
        created_by: user,
        service_key: "claude",
        auth_kind: "oauth_token",
        name: "Previously Saved Claude Login"
      )

      service.send(:persist_captured_credentials!, credentials_json)

      expect(existing_credential.reload.name).to eq("Previously Saved Claude Login")
      created_credential = session_record.reload.integration_credential
      expect(created_credential).to be_present
      expect(created_credential).not_to eq(existing_credential)
      expect(created_credential.name).to eq(session_record.credential_name)
      expect(created_credential.secret).to eq(credentials_json)
      expect(IntegrationCredential.where(account: account, service_key: "claude", auth_kind: "oauth_token").count).to eq(2)
    end
  end

  describe "thread worker context" do
    it "wraps worker blocks with the Rails executor, an AR connection, and tenant context" do
      service = described_class.new(session: session_record, backend: backend)
      executor = object_double(Rails.application.executor)
      connection_pool = ActiveRecord::Base.connection_pool
      wrapped_with_connection = false

      allow(Rails.application).to receive(:executor).and_return(executor)
      allow(connection_pool).to receive(:with_connection).and_wrap_original do |original, *args, &block|
        wrapped_with_connection = true
        original.call(&block)
      end
      allow(TenantContext).to receive(:with_system_access).and_call_original
      allow(TenantContext).to receive(:with).and_call_original

      expect(executor).to receive(:wrap).and_yield

      executed = Queue.new
      thread = service.send(:spawn_worker_thread) { executed << :ran }
      thread.join

      expect(executed.pop).to eq(:ran)
      expect(wrapped_with_connection).to be(true)
      expect(TenantContext).to have_received(:with_system_access)
      expect(TenantContext).to have_received(:with).with(have_attributes(id: session_record.account_id))
    end
  end

  def build_login_exec_context(session_record:, backend:)
    input_reader, input_writer = IO.pipe
    service = described_class.new(session: session_record, backend: backend)
    container = instance_double(Docker::Container)
    observed = {}

    service.instance_variable_set(:@container, container)
    service.instance_variable_set(:@reader, input_reader)
    service.instance_variable_set(:@writer, input_writer)

    allow(backend).to receive(:exec_in_container) do |passed_container, command, **options, &block|
      observed[:container] = passed_container
      observed[:command] = command
      observed[:options] = options
      block.call("Visit https://claude.ai/device")
      [ [], [], 0 ]
    end

    {
      service: service,
      container: container,
      observed: observed,
      input_reader: input_reader,
      input_writer: input_writer
    }
  end

  def close_pipe_context(context)
    return unless context

    context[:input_reader].close unless context[:input_reader].closed?
    context[:input_writer].close unless context[:input_writer].closed?
  end
end
