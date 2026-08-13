# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260729193401_add_container_capability_to_chat_sessions")
require Rails.root.join("db/migrate/20260729193402_drop_mode_from_chat_sessions")

RSpec.describe AddContainerCapabilityToChatSessions, :aggregate_failures do
  let(:add_capability_migration) { described_class.new }
  let(:drop_mode_migration) { DropModeFromChatSessions.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration_chat_session) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "chat_sessions"
    end
  end
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  around do |example|
    drop_mode_migration.down unless connection.column_exists?(:chat_sessions, :mode)
    add_capability_migration.down if connection.column_exists?(:chat_sessions, :container_capability)
    migration_chat_session.reset_column_information

    example.run
  ensure
    add_capability_migration.up unless connection.column_exists?(:chat_sessions, :container_capability)
    drop_mode_migration.up if connection.column_exists?(:chat_sessions, :mode)
    migration_chat_session.reset_column_information
  end

  it "backfills representative api and workspace rows before dropping mode" do
    api_session = create_legacy_session(mode: "api", container_id: nil)
    ready_session = create_legacy_session(mode: "workspace", container_id: "chat-ready")
    stopped_session = create_legacy_session(mode: "workspace", container_id: nil)

    add_capability_migration.up
    migration_chat_session.reset_column_information

    expect(find_session(api_session.id).container_capability).to eq("none")
    expect(find_session(api_session.id).clone_manifest).to eq([])
    expect(find_session(api_session.id).container_requested_at).to be_nil
    expect(find_session(api_session.id).container_ready_at).to be_nil

    expect(find_session(ready_session.id).container_capability).to eq("ready")
    expect(find_session(ready_session.id).container_requested_at).to be_present
    expect(find_session(ready_session.id).container_ready_at).to be_present

    expect(find_session(stopped_session.id).container_capability).to eq("stopped")
    expect(find_session(stopped_session.id).container_requested_at).to be_present
    expect(find_session(stopped_session.id).container_ready_at).to be_nil
  end

  it "drops mode only after the backfill has run" do
    create_legacy_session(mode: "workspace", container_id: "chat-ready")

    add_capability_migration.up
    drop_mode_migration.up

    expect(connection.column_exists?(:chat_sessions, :mode)).to be(false)
    expect(connection.column_exists?(:chat_sessions, :container_capability)).to be(true)
  end

  def create_legacy_session(mode:, container_id:)
    migration_chat_session.create!(
      account_id: account.id,
      auto_approve: false,
      container_id: container_id,
      created_at: Time.zone.parse("2026-07-29 18:00:00 UTC"),
      created_by_id: user.id,
      external_id: SecureRandom.uuid,
      metadata: {},
      mode: mode,
      proxy_token: SecureRandom.hex(32),
      status: "active",
      updated_at: Time.zone.parse("2026-07-29 18:05:00 UTC")
    )
  end

  def find_session(id)
    migration_chat_session.find(id)
  end
end
