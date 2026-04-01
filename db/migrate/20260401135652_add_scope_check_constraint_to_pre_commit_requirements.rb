# frozen_string_literal: true

class AddScopeCheckConstraintToPreCommitRequirements < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :pre_commit_requirements,
      "NOT (project_id IS NOT NULL AND user_id IS NOT NULL)",
      name: "chk_pre_commit_requirements_exclusive_scope"
  end
end
