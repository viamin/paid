# frozen_string_literal: true

class AddZeroDataRetentionToRunners < ActiveRecord::Migration[8.1]
  def change
    add_column :runners, :zero_data_retention, :boolean, default: false, null: false,
      comment: "User declaration that inference requests require zero data retention; provenance is derived from the active provider."
  end
end
