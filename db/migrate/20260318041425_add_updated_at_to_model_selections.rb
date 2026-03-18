# frozen_string_literal: true

class AddUpdatedAtToModelSelections < ActiveRecord::Migration[8.1]
  def change
    add_column :model_selections, :updated_at, :datetime, null: false, default: -> { "CURRENT_TIMESTAMP" }
  end
end
