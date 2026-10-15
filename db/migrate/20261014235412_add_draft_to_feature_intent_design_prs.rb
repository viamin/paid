# frozen_string_literal: true

class AddDraftToFeatureIntentDesignPrs < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:feature_intent_design_prs, :draft)

    add_column :feature_intent_design_prs, :draft, :boolean,
      comment: "GitHub pull request draft state from the most recent synchronization."
  end

  def down
    remove_column :feature_intent_design_prs, :draft if column_exists?(:feature_intent_design_prs, :draft)
  end
end
