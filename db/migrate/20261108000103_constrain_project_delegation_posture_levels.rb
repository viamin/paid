# frozen_string_literal: true

# @spec PROJECT-DELEGATION-001
class ConstrainProjectDelegationPostureLevels < ActiveRecord::Migration[8.1]
  CONSTRAINT_NAME = "chk_project_delegation_postures_level"

  def change
    add_check_constraint :project_delegation_postures,
      "level IN ('conservative', 'bounded_delivery')",
      name: CONSTRAINT_NAME,
      validate: false
  end
end
