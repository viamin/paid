# frozen_string_literal: true

class CreateEgressSecurityEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :egress_security_events, comment: "Audit trail for blocked outbound traffic and redacted secret-extraction attempts captured by the agent container egress gateway." do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, null: true, foreign_key: { on_delete: :cascade }
      t.references :agent_run, null: true, foreign_key: { on_delete: :cascade }
      t.string :event_kind, limit: 40, null: false, comment: "Type of security event: denied_egress, redacted_secret_extraction, allowlist_match."
      t.string :destination_host, limit: 255
      t.integer :destination_port
      t.string :scheme, limit: 10
      t.references :egress_allowlist_entry, null: true, foreign_key: { on_delete: :nullify }, comment: "Optional reference to the matching allowlist entry that triggered the event."
      t.string :matched_rule, limit: 255, comment: "Free-form rule description surfaced in the agent-run audit view."
      t.text :redacted_evidence, comment: "Redacted snippet or fingerprint used to trigger the block. Never contains raw secret material."
      t.string :severity, limit: 20, null: false, default: "info", comment: "Severity for filtering on the audit surface: info, warn, critical."
      t.string :source_layer, limit: 40, null: false, default: "gateway", comment: "Which layer emitted the event: gateway, broker, firewall."
      t.datetime :occurred_at, null: false

      t.timestamps null: false
    end

    add_index :egress_security_events, [ :account_id, :occurred_at ], order: { occurred_at: :desc }, name: "idx_egress_security_events_account_recent"
    add_index :egress_security_events, [ :agent_run_id, :occurred_at ], order: { occurred_at: :desc }, name: "idx_egress_security_events_run_recent"
    add_index :egress_security_events, [ :project_id, :occurred_at ], order: { occurred_at: :desc }, name: "idx_egress_security_events_project_recent"
    add_index :egress_security_events, [ :event_kind ], name: "index_egress_security_events_on_event_kind"

    add_check_constraint :egress_security_events,
      "event_kind IN ('denied_egress', 'redacted_secret_extraction', 'allowlist_match')",
      name: "chk_egress_security_events_kind_valid"
    add_check_constraint :egress_security_events,
      "severity IN ('info', 'warn', 'critical')",
      name: "chk_egress_security_events_severity_valid"
    add_check_constraint :egress_security_events,
      "scheme IS NULL OR scheme IN ('http', 'https')",
      name: "chk_egress_security_events_scheme_valid"
    add_check_constraint :egress_security_events,
      "destination_port IS NULL OR (destination_port > 0 AND destination_port <= 65535)",
      name: "chk_egress_security_events_port_range"

    safety_assured do
      execute <<~SQL
        ALTER TABLE egress_security_events ENABLE ROW LEVEL SECURITY;
        ALTER TABLE egress_security_events FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON egress_security_events
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR (egress_security_events.account_id = paid_current_account_id()))
          WITH CHECK (paid_tenant_bypass() OR (egress_security_events.account_id = paid_current_account_id()));
      SQL
    end
  end

  def down
    safety_assured { execute "DROP POLICY IF EXISTS tenant_isolation ON egress_security_events" }
    safety_assured { execute "ALTER TABLE egress_security_events NO FORCE ROW LEVEL SECURITY" }
    safety_assured { execute "ALTER TABLE egress_security_events DISABLE ROW LEVEL SECURITY" }

    drop_table :egress_security_events
  end
end
