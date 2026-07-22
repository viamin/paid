# frozen_string_literal: true

class AddExtendedFieldsToPreviewSessions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    change_column_default :preview_sessions, :status, from: "provisioning", to: "pending"

    unless column_exists?(:preview_sessions, :framework)
      add_column :preview_sessions, :framework, :string, limit: 64,
        comment: "Detected web framework (rails, phoenix, django, nextjs, etc.) shown as preview metadata."
    end

    unless column_exists?(:preview_sessions, :error_message)
      add_column :preview_sessions, :error_message, :text,
        comment: "Human-readable failure reason shown in the UI error state when status is failed."
    end

    unless column_exists?(:preview_sessions, :last_active_at)
      add_column :preview_sessions, :last_active_at, :datetime,
        comment: "Most recent time the preview was confirmed reachable/interacted with."
    end

    unless column_exists?(:preview_sessions, :created_by_id)
      add_column :preview_sessions, :created_by_id, :bigint,
        comment: "User who started the preview."
    end

    unless column_exists?(:preview_sessions, :account_id)
      add_column :preview_sessions, :account_id, :bigint,
        comment: "Owning account for tenant isolation and RLS."
    end

    unless index_exists?(:preview_sessions, [ :project_id, :created_at ], name: "index_preview_sessions_on_project_id_and_created_at")
      add_index :preview_sessions, [ :project_id, :created_at ],
        order: { created_at: :desc },
        name: "index_preview_sessions_on_project_id_and_created_at",
        algorithm: :concurrently
    end

    unless index_exists?(:preview_sessions, [ :account_id, :status, :expires_at ],
      name: "idx_preview_sessions_on_account_status_expires")
      add_index :preview_sessions, [ :account_id, :status, :expires_at ],
        name: "idx_preview_sessions_on_account_status_expires",
        algorithm: :concurrently
    end

    if index_exists?(:preview_sessions, :tunnel_port, name: "index_preview_sessions_on_tunnel_port_unique")
      remove_index :preview_sessions, name: "index_preview_sessions_on_tunnel_port_unique"
    end

    unless index_exists?(:preview_sessions, :tunnel_port, name: "index_preview_sessions_on_tunnel_port_active")
      add_index :preview_sessions, :tunnel_port,
        unique: true,
        where: "status IN ('pending', 'provisioning', 'starting', 'ready')",
        name: "index_preview_sessions_on_tunnel_port_active",
        algorithm: :concurrently
    end
  end

  def down
    if index_exists?(:preview_sessions, :tunnel_port, name: "index_preview_sessions_on_tunnel_port_active")
      remove_index :preview_sessions, name: "index_preview_sessions_on_tunnel_port_active"
    end
    unless index_exists?(:preview_sessions, :tunnel_port, name: "index_preview_sessions_on_tunnel_port_unique")
      add_index :preview_sessions, :tunnel_port,
        unique: true,
        where: "tunnel_port IS NOT NULL",
        name: "index_preview_sessions_on_tunnel_port_unique"
    end
  end
end
