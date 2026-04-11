# frozen_string_literal: true

class UpdateNotificationsUserForeignKeyOnDeleteNullify < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :notifications, :users
    add_foreign_key :notifications, :users, on_delete: :nullify
  end
end
