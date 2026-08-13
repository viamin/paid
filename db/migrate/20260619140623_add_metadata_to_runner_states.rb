# frozen_string_literal: true

class AddMetadataToRunnerStates < ActiveRecord::Migration[8.1]
  def change
    add_column :runner_states, :metadata, :jsonb, default: {}, null: false,
      comment: "Free-form metadata. Currently stores per-model rate-limit windows " \
               "under the 'rate_limited_models' key so the openrouter_free runner " \
               "can rotate past a rate-limited model without resetting the whole runner."
  end
end
