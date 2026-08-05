# frozen_string_literal: true

class CanonicalizeSchemaDumpMetadata < ActiveRecord::Migration[8.1]
  # @spec POSTGRESQL-PERSISTENCE-007
  CLONE_MANIFEST_COMMENT = "Persisted clone metadata used to reopen a reaped multi-repo chat workspace."
  LEGACY_CLONE_MANIFEST_COMMENT = "Manifest of repos cloned into the chat workspace for container-backed tools"

  def up
    change_column_comment :chat_sessions, :clone_manifest, CLONE_MANIFEST_COMMENT if column_exists?(:chat_sessions, :clone_manifest)

    create_function :paid_current_account_id, version: 1
    create_function :paid_tenant_bypass, version: 1
  end

  def down
    restore_legacy_helper_functions

    return unless column_exists?(:chat_sessions, :clone_manifest)

    change_column_comment :chat_sessions, :clone_manifest, LEGACY_CLONE_MANIFEST_COMMENT
  end

  private

  # Restore the pre-fx, unmanaged bodies so a rolled-back schema dump matches
  # the schema.rb checked in before this migration. fx exposes no helper to
  # revert a function to a prior unmanaged body, so CREATE OR REPLACE is used.
  def restore_legacy_helper_functions
    safety_assured do
      execute <<~SQL
        CREATE OR REPLACE FUNCTION paid_current_account_id()
        RETURNS bigint
        LANGUAGE sql
        STABLE
        AS $$
          SELECT NULLIF(current_setting('paid.current_account_id', true), '')::bigint
        $$;
      SQL
      execute <<~SQL
        CREATE OR REPLACE FUNCTION paid_tenant_bypass()
        RETURNS boolean
        LANGUAGE sql
        STABLE
        AS $$
          SELECT current_setting('paid.bypass_tenant_rls', true) = 'true'
        $$;
      SQL
    end
  end
end
