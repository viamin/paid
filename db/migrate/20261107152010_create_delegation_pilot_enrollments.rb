# frozen_string_literal: true

# Durable evidence for the RDR-080 delegation pilot: one enrollment per
# opted-in project, plus the revision-aware metric snapshots that prove (or
# fail to prove) the pilot's expansion thresholds.
# @spec PROJECT-DELEGATION-007
class CreateDelegationPilotEnrollments < ActiveRecord::Migration[8.1]
  def change
    create_table :delegation_pilot_enrollments do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: { unique: true }
      t.string :posture, null: false, default: "bounded_delivery"
      t.string :status, null: false, default: "active"
      t.string :pause_reason
      t.datetime :paused_at
      t.jsonb :pause_evidence, null: false, default: {}
      t.references :enrolled_by, foreign_key: { to_table: :users }
      t.datetime :enrolled_at, null: false
      t.timestamps
    end

    add_index :delegation_pilot_enrollments, :status

    create_table :delegation_pilot_metric_snapshots do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :enrollment, null: false, foreign_key: { to_table: :delegation_pilot_enrollments }
      t.string :posture, null: false
      t.datetime :window_started_at, null: false
      t.datetime :window_ended_at, null: false
      t.jsonb :metrics, null: false, default: {}
      t.jsonb :exclusions, null: false, default: []
      t.jsonb :revisions, null: false, default: {}
      t.timestamps
    end

    add_index :delegation_pilot_metric_snapshots,
      %i[enrollment_id posture window_ended_at],
      unique: true,
      name: "index_delegation_pilot_metric_snapshots_identity"
  end
end
