# frozen_string_literal: true

class DropPrAggregationEnabledFromProjects < ActiveRecord::Migration[8.1]
  def up
    return unless column_exists?(:projects, :pr_aggregation_enabled)

    safety_assured { remove_column :projects, :pr_aggregation_enabled }
  end

  def down
    return if column_exists?(:projects, :pr_aggregation_enabled)

    add_column :projects, :pr_aggregation_enabled, :boolean, default: false, null: false
  end
end
