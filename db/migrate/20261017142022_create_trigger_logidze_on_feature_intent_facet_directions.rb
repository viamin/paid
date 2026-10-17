# frozen_string_literal: true

class CreateTriggerLogidzeOnFeatureIntentFacetDirections < ActiveRecord::Migration[8.1]
  def change
    create_trigger :logidze_on_feature_intent_facet_directions, on: :feature_intent_facet_directions
  end
end
