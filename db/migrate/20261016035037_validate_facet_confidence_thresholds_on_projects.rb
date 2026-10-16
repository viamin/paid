# frozen_string_literal: true

class ValidateFacetConfidenceThresholdsOnProjects < ActiveRecord::Migration[8.1]
  def up
    validate_check_constraint :projects, name: "projects_intent_threshold_bounds"
    validate_check_constraint :projects, name: "projects_technical_threshold_bounds"
  end

  def down
    # PostgreSQL cannot safely unvalidate a constraint. The preceding migration
    # owns removal when this migration chain is rolled back.
  end
end
