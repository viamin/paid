# frozen_string_literal: true

class AddConfigurationBundleSelectionToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :configuration_bundle_selection_mode, :string,
      comment: "Whether configuration bundle routing favored exploitative or exploratory selection for this run."
    add_column :agent_runs, :configuration_bundle_selection_context, :string,
      comment: "Primary optimization context used for bundle routing, such as task or project."
  end
end
