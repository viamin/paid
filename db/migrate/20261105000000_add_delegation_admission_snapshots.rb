# frozen_string_literal: true

class AddDelegationAdmissionSnapshots < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :projects, :delegation_posture, :string, null: false, default: "conservative",
      comment: "RDR-080 project delegation posture; conservative is fail-closed."
    add_column :projects, :delegation_posture_revision, :integer, null: false, default: 0

    add_column :agent_runs, :admission_snapshot, :jsonb, null: false, default: {},
      comment: "Immutable posture and evidence revisions used to admit this run."
    add_column :agent_runs, :admission_state, :string, null: false, default: "active"
    add_column :agent_runs, :admission_expires_at, :datetime
    add_column :agent_runs, :admission_hold_reason, :text
    add_column :agent_runs, :admission_changed_at, :datetime
    add_index :agent_runs, :admission_state, algorithm: :concurrently
  end
end
