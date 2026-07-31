# frozen_string_literal: true

class AddCloneManifestToChatSessions < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:chat_sessions, :clone_manifest, :jsonb)

    add_column :chat_sessions, :clone_manifest, :jsonb, null: false, default: [],
      comment: "Manifest of repos cloned into the chat workspace for container-backed tools"
  end
end
