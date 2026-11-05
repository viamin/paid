# frozen_string_literal: true

class CreateProjectDelegationMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :project_delegation_metrics do |t|
      t.references :project, null: false, foreign_key: true
      t.string :event_type, null: false
      t.string :cohort, null: false, default: "pilot"
      t.string :issue_key
      t.string :intent_revision, null: false
      t.string :acceptance_revision, null: false
      t.string :evidence_revision, null: false
      t.datetime :occurred_at, null: false
      t.string :reason_code
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :project_delegation_metrics, %i[project_id cohort event_type occurred_at],
      name: "idx_project_delegation_metrics_scope"
    add_index :project_delegation_metrics,
      %i[project_id issue_key intent_revision acceptance_revision evidence_revision event_type],
      name: "idx_project_delegation_metrics_revision_join"
  end
end
