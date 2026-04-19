# frozen_string_literal: true

class AddWeightToProviders < ActiveRecord::Migration[8.1]
  def change
    add_column :providers, :weight, :integer, default: 1, null: false

    add_check_constraint :providers, "weight >= 1", name: "providers_weight_positive"
  end
end
