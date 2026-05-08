# frozen_string_literal: true

class AddRuntimeFieldsToConfigurationBundles < ActiveRecord::Migration[8.1]
  def change
    add_column :configuration_bundles,
      :definition,
      :jsonb,
      null: false,
      default: {},
      comment: "Canonical runtime configuration snapshot used for optimization and fingerprinting"

    add_reference :agent_runs,
      :configuration_bundle,
      foreign_key: { on_delete: :nullify },
      index: true,
      comment: "Configuration bundle assigned to the run before execution."
  end
end
