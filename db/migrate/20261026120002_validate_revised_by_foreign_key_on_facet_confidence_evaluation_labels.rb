# frozen_string_literal: true

# @spec FACET-CONFIDENCE-021
class ValidateRevisedByForeignKeyOnFacetConfidenceEvaluationLabels < ActiveRecord::Migration[8.1]
  def up
    validate_foreign_key :facet_confidence_evaluation_labels, :users, column: :revised_by_id
  end

  def down; end
end
