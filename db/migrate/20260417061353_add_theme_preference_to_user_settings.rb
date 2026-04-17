# frozen_string_literal: true

class AddThemePreferenceToUserSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :user_settings, :theme_preference, :string, default: "system", null: false
  end
end
