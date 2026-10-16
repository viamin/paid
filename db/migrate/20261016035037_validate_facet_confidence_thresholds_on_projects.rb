# frozen_string_literal: true

class ValidateFacetConfidenceThresholdsOnProjects < ActiveRecord::Migration[8.1]
  def up
    if check_constraint_exists?(:projects, name: "projects_intent_threshold_bounds")
      validate_check_constraint :projects, name: "projects_intent_threshold_bounds"
    end
    if check_constraint_exists?(:projects, name: "projects_technical_threshold_bounds")
      validate_check_constraint :projects, name: "projects_technical_threshold_bounds"
    end
  end

  def down
    # PostgreSQL cannot safely unvalidate a constraint. The preceding migration
    # owns removal when this migration chain is rolled back.
  end
end
