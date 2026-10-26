class ValidateRevisedByForeignKeyOnFacetConfidenceEvaluationLabels < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :facet_confidence_evaluation_labels, :users, column: :revised_by_id
  end
end
