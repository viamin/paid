# frozen_string_literal: true

class AddSpeculativeAlternativesToFeatureIntents < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:feature_intents, :speculative_alternatives)
      add_column :feature_intents, :speculative_alternatives, :jsonb, null: false, default: [],
        comment: "Speculative alternatives retained in Paid without GitHub issues (RDR-071 coherent-work publication)."
    end
  end

  def down
    remove_column :feature_intents, :speculative_alternatives if column_exists?(:feature_intents, :speculative_alternatives)
  end
end
