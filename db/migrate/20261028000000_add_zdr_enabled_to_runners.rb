# frozen_string_literal: true

class AddZdrEnabledToRunners < ActiveRecord::Migration[8.1]
  def change
    add_column :runners, :zdr_enabled, :boolean, default: false, null: false,
      comment: "Whether the runner declares zero data retention for provider inference requests."
  end
end
