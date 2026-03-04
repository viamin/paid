# frozen_string_literal: true

class AddFallbackToUserSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :user_settings, :fallback_providers, :jsonb, default: [], null: false
    add_column :user_settings, :fallback_enabled, :boolean, default: true, null: false
  end
end
