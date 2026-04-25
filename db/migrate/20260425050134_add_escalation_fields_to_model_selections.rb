# frozen_string_literal: true

class AddEscalationFieldsToModelSelections < ActiveRecord::Migration[8.1]
  def change
    add_column :model_selections, :escalated_from_tier, :string, limit: 10
    add_check_constraint :model_selections, "escalated_from_tier IS NULL OR escalated_from_tier IN ('low', 'mid', 'high')", name: "model_selections_escalated_from_tier_check"
    add_column :model_selections, :escalated_reason, :string, limit: 255
  end
end
