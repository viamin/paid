# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261113164248_repair_unstarted_personal_chat_index")

RSpec.describe RepairUnstartedPersonalChatIndex do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:draft_ids) { [] }

  around do |example|
    connection.execute("DROP INDEX IF EXISTS #{connection.quote_table_name(described_class::INDEX_NAME)}")
    example.run
  ensure
    if draft_ids.any?
      ChatMessage.where(chat_session_id: draft_ids).delete_all
      ChatSession.where(id: draft_ids).delete_all
    end
    connection.execute("DROP INDEX IF EXISTS #{connection.quote_table_name(described_class::INDEX_NAME)}")
    connection.add_index :chat_sessions, :created_by_id, unique: true,
      where: described_class::DRAFT_PREDICATE, name: described_class::INDEX_NAME
    user.destroy! if draft_ids.any?
    account.destroy! if draft_ids.any?
  end

  # @spec CHAT-API-030
  it "archives surplus closed blank chats and repairs an invalid index" do
    older = create_draft(status: "closed", created_at: 2.days.ago)
    newer = create_draft(status: "closed", created_at: 1.day.ago)
    leave_invalid_index

    migrate_without_tenant_context

    expect(older.reload.status).to eq("archived")
    expect(newer.reload.status).to eq("closed")
    expect(index_valid?).to be(true)
    expect(ChatSession.where(id: draft_ids).count).to eq(2)
  end

  # @spec CHAT-API-030
  it "keeps an active draft over a newer closed blank draft" do
    older = create_draft(status: "active", created_at: 2.days.ago)
    newer = create_draft(status: "closed", created_at: 1.day.ago)
    leave_invalid_index

    migrate_without_tenant_context

    expect(older.reload.status).to eq("active")
    expect(newer.reload.status).to eq("archived")
    expect(index_valid?).to be(true)
  end

  # @spec CHAT-API-030
  it "preserves a draft that gained a user message before the repair" do
    older = create_draft(status: "active", created_at: 2.days.ago)
    newer = create_draft(status: "closed", created_at: 1.day.ago)
    connection.execute(<<~SQL.squish)
      INSERT INTO chat_messages (chat_session_id, content, role, created_at, updated_at)
      VALUES (#{connection.quote(older.id)}, 'Started during deployment', 'user', NOW(), NOW())
    SQL
    leave_invalid_index

    migrate_without_tenant_context

    expect(older.reload.started_at).to be_present
    expect(older.status).to eq("active")
    expect(newer.reload.status).to eq("closed")
    expect(ChatMessage.where(chat_session_id: older.id, role: "user")).to exist
    expect(index_valid?).to be(true)
  end

  # @spec CHAT-API-030
  it "refuses to hide an active duplicate" do
    older = create_draft(status: "active", created_at: 2.days.ago)
    newer = create_draft(status: "active", created_at: 1.day.ago)
    leave_invalid_index

    expect { migrate_without_tenant_context }.to raise_error(/Cannot safely repair/)

    expect(older.reload.status).to eq("active")
    expect(newer.reload.status).to eq("active")
    expect(index_valid?).to be(false)
  end

  private

  def create_draft(status:, created_at:)
    draft = create(:chat_session, :unstarted_draft, account:, created_by: user,
      status:, created_at:, updated_at: created_at)
    draft_ids << draft.id
    draft
  end

  def leave_invalid_index
    expect {
      connection.execute(<<~SQL.squish)
        CREATE UNIQUE INDEX CONCURRENTLY #{connection.quote_table_name(described_class::INDEX_NAME)}
        ON chat_sessions (created_by_id) WHERE #{described_class::DRAFT_PREDICATE}
      SQL
    }.to raise_error(ActiveRecord::StatementInvalid)
    expect(index_valid?).to be(false)
  end

  def index_valid?
    connection.select_value(<<~SQL.squish)
      SELECT indisvalid FROM pg_index
      WHERE indexrelid = to_regclass(#{connection.quote(described_class::INDEX_NAME)})
    SQL
  end

  def migrate_without_tenant_context
    TenantContext.clear!
    connection.transaction { described_class.new.up }
  ensure
    TenantContext.apply_system_access!
  end
end
