class AddRevisedByForeignKeyToFacetConfidenceEvaluationLabels < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_foreign_key :facet_confidence_evaluation_labels, :users, column: :revised_by_id, validate: false
  end
end
