# frozen_string_literal: true

# @spec INTENT-CONFORMANCE-REVIEW-001
class AddDesignDocumentPathsToFeatureIntents < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:feature_intents, :design_document_paths)

    add_column :feature_intents, :design_document_paths, :jsonb, null: false, default: [],
      comment: "Repository paths (RDR plus required LID artifacts) that constitute this feature's approved design, read at approved_design_revision by the intent-conformance reviewer."
  end
end
