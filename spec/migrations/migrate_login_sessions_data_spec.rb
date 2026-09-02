# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260831065000_migrate_login_sessions_data")
require Rails.root.join("db/migrate/20260831065100_drop_old_login_session_tables")

RSpec.describe MigrateLoginSessionsData, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:drop_migration) { DropOldLoginSessionTables.new }
  let(:connection) { ActiveRecord::Base.connection }

  include MigrationSpecHelpers

  around do |example|
    truncate_migration_test_data
    ensure_legacy_tables
    clear_login_session_tables

    example.run
  ensure
    clear_login_session_tables
    drop_migration.up if connection.table_exists?(:claude_login_sessions) || connection.table_exists?(:codex_login_sessions)
    LoginSession.reset_column_information
    truncate_migration_test_data
  end

  it "restores rollback data from merged rows without losing sessions created after deploy" do
    account = create(:account)
    user = create(:user, account: account)

    legacy_ids = seed_legacy_sessions(account:, user:)

    post_deploy_sessions = migrate_and_create_post_deploy_sessions(account:, user:)

    recreate_legacy_tables_for_rollback

    expect { migration.down }.not_to raise_error

    expect(legacy_claude_external_ids).to contain_exactly(legacy_ids.fetch(:claude), post_deploy_sessions.fetch(:claude).external_id)
    expect(legacy_codex_external_ids).to contain_exactly(legacy_ids.fetch(:codex), post_deploy_sessions.fetch(:codex).external_id)
    expect(LoginSession.where(provider: %w[claude codex]).count).to eq(0)
  end

  it "recreates both legacy tables on rollback" do
    drop_migration.up

    expect(connection.table_exists?(:claude_login_sessions)).to be(false)
    expect(connection.table_exists?(:codex_login_sessions)).to be(false)

    expect { drop_migration.down }.not_to raise_error

    expect(connection.table_exists?(:claude_login_sessions)).to be(true)
    expect(connection.table_exists?(:codex_login_sessions)).to be(true)
    expect(connection.column_exists?(:claude_login_sessions, :runner_credential_id)).to be(true)
    expect(connection.index_exists?(:claude_login_sessions, :external_id, unique: true)).to be(true)
    expect(connection.index_exists?(:codex_login_sessions, :session_token, unique: true)).to be(true)
  end

  private

  def ensure_legacy_tables
    drop_migration.down
  end

  def clear_login_session_tables
    connection.execute("DELETE FROM login_sessions")
    connection.execute("DELETE FROM claude_login_sessions") if connection.table_exists?(:claude_login_sessions)
    connection.execute("DELETE FROM codex_login_sessions") if connection.table_exists?(:codex_login_sessions)
  end

  def seed_legacy_sessions(account:, user:)
    claude_id = SecureRandom.uuid
    codex_id = SecureRandom.uuid

    insert_legacy_claude_session(account:, user:, external_id: claude_id, session_token: SecureRandom.hex(32))
    insert_legacy_codex_session(account:, user:, external_id: codex_id, session_token: SecureRandom.hex(32))

    { claude: claude_id, codex: codex_id }
  end

  def migrate_and_create_post_deploy_sessions(account:, user:)
    migration.up

    {
      claude: create_post_deploy_claude_session(account:, user:),
      codex: create_post_deploy_codex_session(account:, user:)
    }
  end

  def recreate_legacy_tables_for_rollback
    drop_migration.up
    drop_migration.down
  end

  def create_post_deploy_claude_session(account:, user:)
    create(
      :login_session,
      account:,
      created_by: user,
      provider: "claude",
      credential_name: "Claude Browser Login",
      status: "awaiting_code",
      oauth_url: "https://claude.example.test/oauth",
      metadata: { "source" => "post-deploy-claude" }
    )
  end

  def create_post_deploy_codex_session(account:, user:)
    create(
      :login_session,
      account:,
      created_by: user,
      provider: "codex",
      credential_name: "Codex Subscription Login",
      status: "awaiting_authorization",
      device_code: "device-code-post-deploy",
      user_code: "POST-DEPLOY",
      verification_uri: "https://codex.example.test/device",
      poll_interval: 7,
      metadata: { "source" => "post-deploy-codex" }
    )
  end

  def insert_legacy_claude_session(account:, user:, external_id:, session_token:)
    connection.execute(<<~SQL.squish)
      INSERT INTO claude_login_sessions (
        account_id, created_by_id, integration_credential_id, runner_credential_id,
        external_id, session_token, credential_name, status,
        oauth_url, error_message, expires_at, submitted_at, completed_at, failed_at,
        container_id, metadata, created_at, updated_at
      )
      VALUES (
        #{account.id}, #{user.id}, NULL, NULL,
        '#{external_id}', '#{session_token}', 'Claude Browser Login', 'awaiting_code',
        'https://claude.example.test/oauth', NULL, CURRENT_TIMESTAMP, NULL, NULL, NULL,
        'container-legacy', '{"source":"legacy-claude"}'::jsonb, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      )
    SQL
  end

  def insert_legacy_codex_session(account:, user:, external_id:, session_token:)
    connection.execute(<<~SQL.squish)
      INSERT INTO codex_login_sessions (
        account_id, created_by_id, runner_credential_id,
        external_id, session_token, credential_name, status,
        device_code, user_code, verification_uri, poll_interval,
        error_message, expires_at, completed_at, failed_at,
        metadata, created_at, updated_at
      )
      VALUES (
        #{account.id}, #{user.id}, NULL,
        '#{external_id}', '#{session_token}', 'Codex Subscription Login', 'awaiting_authorization',
        'device-code-legacy', 'LEGACY-CODE', 'https://codex.example.test/device', 5,
        NULL, CURRENT_TIMESTAMP, NULL, NULL,
        '{"source":"legacy-codex"}'::jsonb, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      )
    SQL
  end

  def legacy_claude_external_ids
    connection.select_values("SELECT external_id FROM claude_login_sessions ORDER BY external_id")
  end

  def legacy_codex_external_ids
    connection.select_values("SELECT external_id FROM codex_login_sessions ORDER BY external_id")
  end
end
