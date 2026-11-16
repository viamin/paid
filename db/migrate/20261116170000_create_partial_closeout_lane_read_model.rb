# frozen_string_literal: true

class CreatePartialCloseoutLaneReadModel < ActiveRecord::Migration[8.1]
  def change
    create_table :partial_closeout_projections do |t|
      t.references :project, null: false, foreign_key: true, index: { unique: true }
      t.datetime :computed_at, comment: "When the last successful stall projection was committed."
      t.string :generation, comment: "Identity of the last atomically replaced projection."
      t.datetime :input_watermark, comment: "Newest admission input included in the projection."
      t.datetime :last_failure_at, comment: "When the latest projection attempt failed."
      t.jsonb :last_failure, null: false, default: {}, comment: "Bounded metadata for the latest projection failure."
      t.timestamps
    end

    create_table :partial_closeout_projection_entries do |t|
      t.references :project, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true, index: { unique: true }
      t.string :evidence_digest, null: false, comment: "Closeout evidence generation used for this stall."
      t.jsonb :status, null: false, default: {}, comment: "Persisted closeout outcome and prerequisites."
      t.jsonb :blockers, null: false, default: [], comment: "Structured live-admission diagnostics."
      t.string :projection_generation, null: false, comment: "Checkpoint generation that produced this row."
      t.timestamps
    end

    add_index :partial_closeout_projection_entries,
      [ :project_id, :projection_generation ],
      name: "idx_partial_closeout_projection_entries_generation"
  end
end
