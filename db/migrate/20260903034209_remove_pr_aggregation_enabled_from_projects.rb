# frozen_string_literal: true

class RemovePrAggregationEnabledFromProjects < ActiveRecord::Migration[8.1]
  def change
    return unless table_exists?(:projects)
    return unless column_exists?(:projects, :pr_aggregation_enabled)

    safety_assured { remove_column :projects, :pr_aggregation_enabled, :boolean }
  end
end
