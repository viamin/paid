# frozen_string_literal: true

# @spec FACET-CONFIDENCE-021
class AddRevisedByForeignKeyToFacetConfidenceEvaluationLabels < ActiveRecord::Migration[8.1]
  def up
    add_foreign_key :facet_confidence_evaluation_labels, :users, column: :revised_by_id, validate: false
  end

  def down
    remove_foreign_key :facet_confidence_evaluation_labels, column: :revised_by_id
  end
end
