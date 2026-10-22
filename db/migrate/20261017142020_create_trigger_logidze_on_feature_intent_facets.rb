# frozen_string_literal: true

class CreateTriggerLogidzeOnFeatureIntentFacets < ActiveRecord::Migration[8.1]
  def change
    create_trigger :logidze_on_feature_intent_facets, on: :feature_intent_facets
  end
end
