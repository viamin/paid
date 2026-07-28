# frozen_string_literal: true

class AddDefaultAutoApproveToUserSettings < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:user_settings, :default_auto_approve)

    add_column :user_settings, :default_auto_approve, :boolean,
      default: true, null: false,
      comment: "Default value for the auto-approve actions checkbox when starting a new chat session"
  end
end
