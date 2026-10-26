class AddRevisedByForeignKeyToFacetConfidenceEvaluationLabels < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :facet_confidence_evaluation_labels, :users, column: :revised_by_id, validate: false
  end
end
