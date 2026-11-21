# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe Onboarding::ConfigureChatRunner do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let!(:user) { create(:user, :owner, account:) }
  let(:threads) { [] }
  let(:published_models) { [] }
  let(:writer_ready) { Queue.new }
  let(:release_writer) { Queue.new }

  before do
    Onboarding::StartOnboarding.call(account:)
    Onboarding::CompleteStep.call(account:, step: "account_profile")
    allow(AgentHarness).to receive(:check_provider).and_return(status: "ok")
  end

  after do
    release_writer << true
    threads.each { |thread| thread.kill.join if thread.alive? }
    account.destroy!
    published_models.each { |model| model.destroy! if model.persisted? && LlmModel.exists?(model.id) }
  end

  # @spec ONBOARD-CHAT-014 MODEL-AVAILABILITY-008
  it "waits for a direct provider's first catalog and availability publication before creating its runner" do
    writer = start_catalog_publication
    reader, pid = start_onboarding
    wait_for_catalog_lock(reader, pid)
    release_writer << true
    threads.each { |thread| raise "Catalog publication timed out" unless thread.join(15) }
    writer.value

    expect(reader.value.chat_session.model).to eq(published_models.sole.model_id)
    expect(account.onboarding_steps.find_by!(step: "chat_api_key")).to be_completed
    expect(user.provider_api_keys.count).to eq(1)
  end

  def start_catalog_publication
    allow(Models::RegistryModels).to receive(:fetch).and_return({})
    allow(Models::SeedKnownModels).to receive(:call) do |registry_models:|
      published_models << create(:llm_model, provider: "deepseek", model_id: "deepseek-first-publication",
        tier: "low", supports_tools: true)
      writer_ready << true
      release_writer.pop
      1
    end
    allow(Models::ReconcileAvailability).to receive(:refresh_known_contexts!) do
      create(:model_availability_check, llm_model: published_models.sole,
        runner_key: "opencode", auth_type: "api_key")
      { "opencode:api_key" => 1 }
    end
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TenantContext.with_system_access { ModelsSyncJob.new.perform }
      end
    end
    threads << writer
    Timeout.timeout(10) { writer_ready.pop }
    writer
  end

  def start_onboarding
    ready = Queue.new
    reader = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        TenantContext.with(account) do
          raise "Reader bypasses tenant RLS" if TenantContext.bypass_enabled?

          ready << connection.select_value("SELECT pg_backend_pid()")
          described_class.call(account: Account.find(account.id), user: User.find(user.id),
            api_service_type: "deepseek", api_key: "fixture-only")
        end
      end
    end
    threads << reader
    [ reader, Timeout.timeout(10) { ready.pop } ]
  end

  def wait_for_catalog_lock(reader, pid)
    Timeout.timeout(10) do
      loop do
        waiting = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
          SELECT EXISTS (SELECT 1 FROM pg_locks
            WHERE pid = #{Integer(pid)} AND locktype = 'advisory' AND NOT granted)
        SQL
        break if waiting
        reader.value unless reader.alive?
        Thread.pass
      end
    end
  end
end
