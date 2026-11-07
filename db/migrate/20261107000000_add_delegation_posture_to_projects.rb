# frozen_string_literal: true

class AddDelegationPostureToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :delegation_posture, :string, default: "conservative", null: false,
      comment: "Project-level delegation posture: conservative (default) or bounded_delivery"
    add_column :projects, :delegation_posture_selected_by_id, :bigint,
      comment: "User who most recently selected the delegation posture"
    add_column :projects, :delegation_posture_selected_at, :datetime,
      comment: "Timestamp when delegation posture was last selected"
    add_column :projects, :delegation_policy_signature, :string,
      comment: "Immutable policy signature at the time of posture selection"
    add_column :projects, :delegation_enabled_actions, :jsonb, default: {}, null: false,
      comment: "Enabled action classes for the current delegation posture"

    add_foreign_key :projects, :users, column: :delegation_posture_selected_by_id
    add_index :projects, :delegation_posture
  end
end
