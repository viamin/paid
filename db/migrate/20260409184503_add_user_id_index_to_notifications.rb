# frozen_string_literal: true

class AddUserIdIndexToNotifications < ActiveRecord::Migration[8.1]
  def change
    add_index :notifications, :user_id
  end
end
