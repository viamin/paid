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
    return unless column_exists?(:chat_sessions, :clone_manifest)

    change_column_comment :chat_sessions, :clone_manifest, LEGACY_CLONE_MANIFEST_COMMENT
  end
end
