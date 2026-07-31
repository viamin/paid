# frozen_string_literal: true

class AddContainerCapabilityToChatSessions < ActiveRecord::Migration[8.1]
  class MigrationChatSession < ActiveRecord::Base
    self.table_name = "chat_sessions"
  end

  def up
    return unless table_exists?(:chat_sessions)

    add_column :chat_sessions, :container_capability, :string,
      default: "none",
      null: false,
      comment: "Container capability lifecycle for the chat session: none, pending, provisioning, ready, failed, or stopped." unless column_exists?(:chat_sessions, :container_capability)
    add_column :chat_sessions, :container_requested_at, :datetime,
      comment: "When the session most recently requested a container-backed workspace." unless column_exists?(:chat_sessions, :container_requested_at)
    add_column :chat_sessions, :container_ready_at, :datetime,
      comment: "When the session's container-backed workspace most recently became ready." unless column_exists?(:chat_sessions, :container_ready_at)
    add_column :chat_sessions, :clone_manifest, :jsonb,
      default: [],
      null: false,
      comment: "Persisted clone metadata used to reopen a reaped multi-repo chat workspace." unless column_exists?(:chat_sessions, :clone_manifest)

    backfill_chat_sessions!
  end

  def down
    return unless table_exists?(:chat_sessions)

    safety_assured do
      remove_column :chat_sessions, :clone_manifest if column_exists?(:chat_sessions, :clone_manifest)
      remove_column :chat_sessions, :container_ready_at if column_exists?(:chat_sessions, :container_ready_at)
      remove_column :chat_sessions, :container_requested_at if column_exists?(:chat_sessions, :container_requested_at)
      remove_column :chat_sessions, :container_capability if column_exists?(:chat_sessions, :container_capability)
    end
  end

  private

  def backfill_chat_sessions!
    MigrationChatSession.reset_column_information

    MigrationChatSession.find_each do |chat_session|
      attributes = {
        clone_manifest: chat_session[:clone_manifest].presence || []
      }

      if column_exists?(:chat_sessions, :mode)
        attributes[:container_capability] = container_capability_for(chat_session)
        attributes[:container_requested_at] = container_requested_at_for(chat_session)
        attributes[:container_ready_at] = container_ready_at_for(chat_session)
      end

      chat_session.update_columns(attributes)
    end
  end

  def container_capability_for(chat_session)
    case chat_session[:mode]
    when "api" then "none"
    when "workspace" then chat_session[:container_id].present? ? "ready" : "stopped"
    else "none"
    end
  end

  def container_requested_at_for(chat_session)
    return unless chat_session[:mode] == "workspace"

    chat_session[:container_requested_at] || chat_session[:updated_at] || chat_session[:created_at]
  end

  def container_ready_at_for(chat_session)
    return unless chat_session[:mode] == "workspace" && chat_session[:container_id].present?

    chat_session[:container_ready_at] || chat_session[:updated_at] || chat_session[:created_at]
  end
end
