# frozen_string_literal: true

class CreatePreviewSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :preview_sessions,
      comment: "Live web app preview sessions bridging a tunnel port to the Rails reverse proxy for human review." do |t|
      t.references :project, null: false, foreign_key: true,
        comment: "Project the preview belongs to; drives account-scoped authorization."
      t.references :agent_run, null: true, foreign_key: true,
        comment: "Optional originating agent run that produced the previewed changes."
      t.string :token, null: false, limit: 64,
        comment: "Opaque, random secret embedded in the proxy path /previews/:token/*. Acts as the proxy credential."
      t.string :branch_name, null: true, limit: 255,
        comment: "Git branch (or commit context) checked out in the preview container."
      t.string :container_id, null: true, limit: 128,
        comment: "Docker container id running the previewed web app behind the tunnel."
      t.integer :tunnel_port, null: true,
        comment: "Allocated localhost port on the Rails host that the rathole tunnel bridges to the container app."
      t.string :status, null: false, limit: 50, default: "provisioning",
        comment: "Lifecycle state: provisioning, starting, ready, active, expiring, stopped, failed."
      t.datetime :expires_at, null: true,
        comment: "Hard TTL after which the preview is stopped and its container/tunnel/port are reclaimed."
      t.datetime :last_accessed_at, null: true,
        comment: "Last time the proxy served a request for this session; used for idle-based expiry."
      t.timestamps
    end

    add_index :preview_sessions, :token, unique: true,
      name: "index_preview_sessions_on_token"
    add_index :preview_sessions, [ :project_id, :status ],
      name: "index_preview_sessions_on_project_and_status"
    add_index :preview_sessions, :tunnel_port,
      unique: true,
      where: "tunnel_port IS NOT NULL",
      name: "index_preview_sessions_on_tunnel_port_unique"
    add_index :preview_sessions, [ :status, :expires_at ],
      name: "index_preview_sessions_on_status_and_expires_at"

    safety_assured do
      execute "ALTER TABLE preview_sessions ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE preview_sessions FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON preview_sessions
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = preview_sessions.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = preview_sessions.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
      SQL
    end
  end
end
