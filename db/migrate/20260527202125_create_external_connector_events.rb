# frozen_string_literal: true

class CreateExternalConnectorEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :external_connector_events, comment: "Events ingested from external connectors (Jira, Linear, Slack, etc.) for coexistence workflows." do |t|
      t.references :project, null: false, foreign_key: true, comment: "Project this connector event belongs to."
      t.references :account, null: false, foreign_key: true, comment: "Account this connector event belongs to."
      t.string :connector_key, null: false, comment: "Connector source key from Interop::Catalog (e.g. jira, linear, slack)."
      t.string :event_type, null: false, comment: "Connector-specific event type (e.g. issue_created, pipeline_completed, message_posted)."
      t.string :external_event_id, null: false, comment: "Unique event ID from the external system, used for deduplication."
      t.jsonb :payload, null: false, default: {}, comment: "Raw event payload from the external system."
      t.jsonb :normalized_data, default: {}, comment: "Normalized data extracted from the payload for query and comparison."
      t.datetime :occurred_at, comment: "Timestamp when the event occurred in the external system."
      t.datetime :processed_at, comment: "Timestamp when the event was processed by Paid."
      t.string :status, null: false, default: "pending", comment: "Processing status: pending, processed, failed."

      t.timestamps
    end

    add_index :external_connector_events, [ :project_id, :connector_key, :event_type ],
      name: "idx_connector_events_project_connector_type"
    add_index :external_connector_events, [ :account_id, :connector_key ],
      name: "idx_connector_events_account_connector"
    add_index :external_connector_events, [ :project_id, :connector_key, :external_event_id ],
      unique: true,
      name: "idx_connector_events_project_external_id"
    add_index :external_connector_events, [ :status, :created_at ],
      name: "idx_connector_events_status_created"
    add_index :external_connector_events, :occurred_at,
      name: "idx_connector_events_occurred_at"

    reversible do |dir|
      dir.up do
        safety_assured do
          execute <<-SQL.squish
            ALTER TABLE external_connector_events ENABLE ROW LEVEL SECURITY;

            CREATE POLICY external_connector_events_account_isolation ON external_connector_events
              USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
              WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id());

            CREATE POLICY external_connector_events_project_access ON external_connector_events
              USING (
                paid_tenant_bypass() OR EXISTS (
                  SELECT 1
                  FROM projects
                  WHERE projects.id = external_connector_events.project_id
                    AND projects.account_id = paid_current_account_id()
                )
              )
              WITH CHECK (
                paid_tenant_bypass() OR EXISTS (
                  SELECT 1
                  FROM projects
                  WHERE projects.id = external_connector_events.project_id
                    AND projects.account_id = paid_current_account_id()
                )
              );
          SQL
        end
      end

      dir.down do
        safety_assured do
          execute <<-SQL.squish
            DROP POLICY IF EXISTS external_connector_events_project_access ON external_connector_events;
            DROP POLICY IF EXISTS external_connector_events_account_isolation ON external_connector_events;
            ALTER TABLE external_connector_events DISABLE ROW LEVEL SECURITY;
          SQL
        end
      end
    end
  end
end
