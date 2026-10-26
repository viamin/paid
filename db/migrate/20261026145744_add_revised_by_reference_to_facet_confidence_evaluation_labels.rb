# frozen_string_literal: true

# @spec FACET-CONFIDENCE-021
class AddRevisedByReferenceToFacetConfidenceEvaluationLabels < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_reference :facet_confidence_evaluation_labels, :revised_by,
      index: { algorithm: :concurrently },
      comment: "Authenticated sole judge who recorded the post-unblinding correction."
  end
end
