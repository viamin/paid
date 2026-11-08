# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261108212805_add_started_at_to_chat_sessions")

RSpec.describe AddStartedAtToChatSessions, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }
  let(:migration_chat_session) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "chat_sessions"
    end
  end

  around do |example|
    migration.down if connection.column_exists?(:chat_sessions, :started_at)
    migration_chat_session.reset_column_information

    example.run
  ensure
    migration.up unless connection.column_exists?(:chat_sessions, :started_at)
    migration_chat_session.reset_column_information
    cleanup_test_data
  end

  # @spec CHAT-API-030
  it "releases discarded drafts' workspace resources before deleting them" do
    retained_draft = create_legacy_draft(created_at: 2.minutes.ago)
    discarded_draft = create_legacy_draft(created_at: 3.minutes.ago, container_capability: "ready",
      container_id: "container-123", workspace_volume: "volume-123")
    allow(Rails.logger).to receive(:info).and_call_original

    migration.up

    expect(migration_chat_session.find(retained_draft.id)).to be_present
    expect { migration_chat_session.find(discarded_draft.id) }.to raise_error(ActiveRecord::RecordNotFound)
    expect(Rails.logger).to have_received(:info).with(
      hash_including(message: "chat_session.cleanup_container", chat_session_id: discarded_draft.id)
    )
    expect(Rails.logger).to have_received(:info).with(
      hash_including(message: "chat_session.cleanup_volume", chat_session_id: discarded_draft.id)
    )
  end

  private

  def create_legacy_draft(created_at:, container_capability: "none", container_id: nil, workspace_volume: nil)
    migration_chat_session.create!(
      account_id: account.id,
      auto_approve: false,
      clone_manifest: [],
      container_capability: container_capability,
      container_id: container_id,
      created_at: created_at,
      created_by_id: user.id,
      external_id: SecureRandom.uuid,
      inbox_item_metadata: {},
      metadata: {},
      proxy_token: SecureRandom.hex(32),
      status: "active",
      updated_at: created_at,
      workspace_volume: workspace_volume
    )
  end

  def cleanup_test_data
    connection.execute("DELETE FROM chat_sessions WHERE created_by_id = #{connection.quote(user.id)}")
    user.destroy!
    account.destroy!
  end
end
