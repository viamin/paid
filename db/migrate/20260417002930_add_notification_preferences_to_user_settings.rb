# frozen_string_literal: true

class AddNotificationPreferencesToUserSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :user_settings, :notification_preferences, :jsonb, default: {}, null: false
  end
end
