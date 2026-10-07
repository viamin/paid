# frozen_string_literal: true

class CreateDependabotAlertCoverages < ActiveRecord::Migration[8.1]
  def up
    create_table :dependabot_alert_coverages,
      comment: "Durable alert-level Dependabot remediation coverage and escalation evidence." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.integer :alert_number, null: false, comment: "GitHub Dependabot alert number within the repository."
      t.string :dependency_name, null: false
      t.string :dependency_ecosystem, null: false
      t.string :manifest_path
      t.string :advisory_ghsa_id, null: false
      t.string :advisory_cve_id
      t.string :alert_state, null: false, default: "open"
      t.string :coverage_state, null: false, default: "awaiting_processing"
      t.string :reason, null: false, default: "unknown"
      t.jsonb :remediation_pull_requests, null: false, default: []
      t.jsonb :evidence, null: false, default: {}
      t.datetime :first_detected_at, null: false
      t.datetime :last_detected_at, null: false
      t.datetime :escalated_at
      t.references :accepted_by, foreign_key: { to_table: :users }
      t.text :acceptance_reason
      t.datetime :acceptance_expires_at
      t.timestamps
    end

    add_index :dependabot_alert_coverages, [ :project_id, :alert_number ], unique: true
    add_index :dependabot_alert_coverages,
      [ :project_id, :dependency_ecosystem, :dependency_name, :advisory_ghsa_id, :manifest_path ],
      unique: true,
      name: "index_dependabot_coverages_on_dependency_advisory_identity"
    add_index :dependabot_alert_coverages, [ :project_id, :coverage_state ]

    safety_assured do
      execute <<~SQL
        ALTER TABLE dependabot_alert_coverages ENABLE ROW LEVEL SECURITY;
        ALTER TABLE dependabot_alert_coverages FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON dependabot_alert_coverages
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR (dependabot_alert_coverages.account_id = paid_current_account_id()))
          WITH CHECK (paid_tenant_bypass() OR (dependabot_alert_coverages.account_id = paid_current_account_id()));
      SQL
    end
  end

  def down
    safety_assured { execute "DROP POLICY IF EXISTS tenant_isolation ON dependabot_alert_coverages" }
    safety_assured { execute "ALTER TABLE dependabot_alert_coverages NO FORCE ROW LEVEL SECURITY" }
    safety_assured { execute "ALTER TABLE dependabot_alert_coverages DISABLE ROW LEVEL SECURITY" }

    drop_table :dependabot_alert_coverages
  end
end
