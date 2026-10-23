# frozen_string_literal: true

# RDR-077 (#4511) — phase policy/grants/rollout foundation, plus the Inbox
# ownership, personal-removal, and operations-contract storage the rest of the
# implementation tree needs.
#
# Nothing here changes behavior: `Automation::RolloutGuard` keeps the phase
# model default-off, and every new table starts empty, so pre-existing
# projects keep their currently effective capabilities.
class CreateAutomationPhaseAuthorization < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :automation_phase_settings, :jsonb, default: {}, null: false,
      comment: "RDR-077 phase defaults: { \"phases\" => { \"coding\" => true }, \"release\" => false, \"deployment\" => false }. Empty means derive from current capability columns."

    create_table :work_item_continuation_grants do |t|
      t.references :project, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true
      t.string :start_phase, null: false, comment: "Phase the manual action started in; the grant covers it and later delivery phases."
      t.string :endpoint, null: false, comment: "Last phase the grant covers: issue_preparation, coding, or merge."
      t.string :source, null: false, default: "manual_start", comment: "How the grant was created. Only manual_start is supported today."
      t.references :created_by, foreign_key: { to_table: :users }
      t.datetime :completed_at, comment: "When the endpoint's work landed. A completed grant is not reactivated by reopening work."
      t.datetime :revoked_at
      t.references :revoked_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :work_item_continuation_grants, %i[project_id issue_id endpoint],
      name: "index_continuation_grants_work_item_endpoint"
    add_index :work_item_continuation_grants, %i[issue_id revoked_at completed_at],
      name: "index_continuation_grants_active_lookup"

    create_table :inbox_request_ownerships do |t|
      t.references :project, foreign_key: true
      t.string :request_key, null: false, comment: "Stable request identity: \"<kind>:<record_id>\"."
      t.string :entry_kind, null: false
      t.bigint :record_id, null: false
      t.string :responsible_phase, comment: "Phase that owns the request; NULL for platform requests."
      t.string :classification_state, null: false, default: "classified",
        comment: "classified | unknown | platform"
      t.string :origin_kind, comment: "Originating work: issue | pull_request | run | project | notification."
      t.bigint :origin_id
      t.datetime :classified_at, null: false
      t.timestamps
    end
    add_index :inbox_request_ownerships, :request_key, unique: true
    add_index :inbox_request_ownerships, %i[project_id responsible_phase]

    create_table :inbox_removals do |t|
      t.references :user, null: false, foreign_key: true
      t.references :project, foreign_key: true
      t.string :request_key, null: false
      t.string :entry_kind, null: false
      t.string :request_occurrence, null: false,
        comment: "Occurrence token at removal time; a newer occurrence makes the request eligible again."
      t.string :responsible_phase
      t.datetime :removed_at, null: false
      t.datetime :cleared_at, comment: "When a qualifying return event restored the request."
      t.timestamps
    end
    add_index :inbox_removals, %i[user_id request_key request_occurrence], unique: true,
      name: "index_inbox_removals_user_request_occurrence"
    add_index :inbox_removals, %i[project_id responsible_phase]
  end
end
