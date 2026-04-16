# frozen_string_literal: true

class AddMaxAutoPickOpenPrsToUserSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :user_settings, :max_auto_pick_open_prs, :integer, default: 1, null: false
  end
end
