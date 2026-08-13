# frozen_string_literal: true

class AddPrAggregationEnabledToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :pr_aggregation_enabled, :boolean, default: false, null: false
  end
end
