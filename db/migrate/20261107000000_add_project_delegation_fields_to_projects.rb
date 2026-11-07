# frozen_string_literal: true

class AddProjectDelegationFieldsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :delegation_posture, :string, default: "conservative", null: false,
      comment: "Project delegation posture: conservative (default) or bounded_delivery"
    add_column :projects, :delegation_authorized_by_id, :bigint,
      comment: "User who authorized the current delegation posture"
    add_column :projects, :delegation_authorized_at, :datetime,
      comment: "When the current delegation posture was authorized"
    add_column :projects, :delegation_posture_signature, :string,
      comment: "Policy signature pinned at posture authorization time"
    add_column :projects, :delegation_enabled_action_classes, :jsonb, default: [], null: false,
      comment: "Array of action classes enabled under the current delegation posture"

    add_check_constraint :projects,
      "delegation_posture IN ('conservative', 'bounded_delivery')",
      name: "chk_projects_delegation_posture"

    add_index :projects, [:delegation_posture], name: "index_projects_on_delegation_posture"
    add_index :projects, [:delegation_authorized_by_id], name: "index_projects_on_delegation_authorized_by_id"
    add_index :projects, [:delegation_authorized_at], name: "index_projects_on_delegation_authorized_at"

    add_foreign_key :projects, :users, column: :delegation_authorized_by_id, validate: false
  end
end
