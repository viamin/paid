# frozen_string_literal: true

# @spec POSTGRESQL-PERSISTENCE-021
class ValidateProjectDelegationPosturesLevelConstraint < ActiveRecord::Migration[8.1]
  def change
    validate_check_constraint :project_delegation_postures, name: "chk_project_delegation_postures_level"
  end
end
