class AddInferredFitToFeatureIntentFacetAssessments < ActiveRecord::Migration[8.1]
  def change
    add_column :feature_intent_facet_assessments, :inferred_fit, :text
  end
end
