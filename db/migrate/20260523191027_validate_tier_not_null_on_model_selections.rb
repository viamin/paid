# frozen_string_literal: true

class ValidateTierNotNullOnModelSelections < ActiveRecord::Migration[8.1]
  def up
    validate_check_constraint :model_selections, name: "model_selections_tier_not_null"
    change_column_null :model_selections, :tier, false
    remove_check_constraint :model_selections, name: "model_selections_tier_not_null"
  end

  def down
    add_check_constraint :model_selections, "tier IS NOT NULL", name: "model_selections_tier_not_null", validate: false
    change_column_null :model_selections, :tier, true
  end
end
