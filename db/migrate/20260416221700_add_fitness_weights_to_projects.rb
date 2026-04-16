# frozen_string_literal: true

# Per-project overrides for the prompt evolution fitness function.
# Stored as JSONB so dimension weights and reference values can be tuned
# without schema changes; defaults to {} so existing projects fall back
# to PromptEvolution::FitnessFunction defaults.
class AddFitnessWeightsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :fitness_weights, :jsonb, default: {}, null: false
  end
end
