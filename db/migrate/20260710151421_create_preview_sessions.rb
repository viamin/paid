# frozen_string_literal: true

class CreatePreviewSessions < ActiveRecord::Migration[8.1]
  def up
    if table_exists?(:preview_sessions)
      enable_preview_sessions_rls if column_exists?(:preview_sessions, :account_id)
      return
    end

    create_table :preview_sessions,
      comment: "Live web-app preview sessions exposed to reviewers via the same-origin " \
               "/previews/:token reverse proxy (RDR-045)." do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade },
        comment: "Owning account for tenant isolation and RLS."
      t.references :project, null: false, foreign_key: { on_delete: :cascade },
        comment: "Project whose branch is being previewed."
      t.references :agent_run, foreign_key: { on_delete: :nullify },
        comment: "Agent run that produced the branch, when the preview reuses an agent container."
      t.references :created_by, foreign_key: { to_table: :users },
        comment: "User who started the preview."
      t.string :token, null: false, limit: 64,
        comment: "Opaque, URL-safe token used as the /previews/:token path segment and auth credential."
      t.string :branch_name, null: false, limit: 255,
        comment: "Git branch checked out in the preview container (PR branch or default branch)."
      t.string :framework, limit: 64,
        comment: "Detected web framework (rails, phoenix, django, nextjs, etc.) shown as preview metadata."
      t.string :container_id, limit: 128,
        comment: "Docker container id hosting the previewed app."
      t.integer :tunnel_port,
        comment: "Allocated localhost port the reverse proxy forwards /previews/:token traffic to."
      t.string :status, null: false, default: "pending", limit: 32,
        comment: "Lifecycle state: pending, provisioning, starting, ready, stopped, or failed."
      t.datetime :expires_at, null: false,
        comment: "TTL deadline after which the preview is auto-stopped and cleaned up."
      t.datetime :last_active_at,
        comment: "Most recent time the preview was confirmed reachable/interacted with."
      t.text :error_message,
        comment: "Human-readable failure reason shown in the UI error state when status is failed."
      t.timestamps
    end

    add_index :preview_sessions, :token, unique: true
    add_index :preview_sessions, [ :project_id, :status ]
    add_index :preview_sessions, [ :project_id, :created_at ],
      order: { created_at: :desc }
    add_index :preview_sessions, [ :account_id, :status, :expires_at ],
      name: "idx_preview_sessions_on_account_status_expires"

    enable_preview_sessions_rls
  end

  def down
    # Always a no-op. `20260722102221_add_extended_fields_to_preview_sessions`
    # creates the same `idx_preview_sessions_on_account_status_expires` index on
    # the legacy-table upgrade path, so that index cannot reliably distinguish
    # a table this migration created from a pre-existing legacy table. Dropping
    # the table during rollback would destroy legacy data, so we leave the table
    # in place regardless. The `up` path is idempotent and handles a
    # pre-existing table gracefully.
  end

  private

  def enable_preview_sessions_rls
    safety_assured do
      execute <<~SQL
        ALTER TABLE preview_sessions ENABLE ROW LEVEL SECURITY;
        ALTER TABLE preview_sessions FORCE ROW LEVEL SECURITY;
        DROP POLICY IF EXISTS tenant_isolation ON preview_sessions;
        CREATE POLICY tenant_isolation ON preview_sessions
          USING (
            paid_tenant_bypass() OR preview_sessions.account_id = paid_current_account_id()
          )
          WITH CHECK (
            paid_tenant_bypass() OR preview_sessions.account_id = paid_current_account_id()
          );
      SQL
    end
  end
end
