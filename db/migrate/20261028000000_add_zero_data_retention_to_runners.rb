# frozen_string_literal: true

class AddZeroDataRetentionToRunners < ActiveRecord::Migration[8.1]
  def change
    add_column :runners, :zero_data_retention, :boolean, default: false, null: false,
      comment: "Whether this runner requires zero data retention from its inference provider."
  end
end
