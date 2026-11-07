# frozen_string_literal: true

# Display-only partial-closeout stall projection (RDR-081, #4912): one
# project checkpoint per project recording the last successful recomputation
# (including an empty result), and one row per projected stalled issue.
# Admission stays with DefaultCandidateSource.eligible_scope; these tables are
# read-model storage only.
# @spec PARTIAL-CLOSEOUT-042
class CreatePartialCloseoutStallProjections < ActiveRecord::Migration[8.1]
  def up
    create_table :partial_closeout_stall_checkpoints, comment: "Project checkpoints for the display-only partial-closeout stall projection (RDR-081)." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true, index: { unique: true }
      t.datetime :computed_at, comment: "When the last successful projection was committed; null until one succeeds."
      t.bigint :generation, null: false, default: 0, comment: "Identity of the last successful atomic row replacement."
      t.datetime :input_watermark, comment: "Newest admission-relevant input included in the last successful computation."
      t.datetime :last_failure_at, comment: "When the latest failed recomputation attempt occurred."
      t.jsonb :last_failure, null: false, default: {}, comment: "Bounded failure metadata for operator diagnosis."
      t.timestamps
    end

    create_table :partial_closeout_stalls, comment: "Persisted stalled-issue rows of the display-only partial-closeout stall projection (RDR-081)." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true, index: false
      t.references :issue, null: false, foreign_key: true, index: { unique: true }
      t.string :evidence_digest, null: false, comment: "Outcome-generation digest the stall was computed against."
      t.jsonb :status, null: false, default: {}, comment: "Serialized CloseoutStatus display payload: outcome, reason, prerequisites, evidence, technical evidence."
      t.jsonb :blockers, null: false, default: [], comment: "Additive structured blockers CloseoutStatus produced for the stall."
      t.bigint :projection_generation, null: false, comment: "Checkpoint generation that produced this row."
      t.timestamps
    end
    add_index :partial_closeout_stalls, [ :project_id, :projection_generation ],
      name: "index_partial_closeout_stalls_on_project_and_generation"
  end

  def down
    drop_table :partial_closeout_stalls
    drop_table :partial_closeout_stall_checkpoints
  end
end
