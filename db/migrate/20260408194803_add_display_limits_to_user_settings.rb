# frozen_string_literal: true

class AddDisplayLimitsToUserSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :user_settings, :max_issues_per_page, :integer, null: false, default: 50
    add_column :user_settings, :max_prs_per_page, :integer, null: false, default: 50
  end
end
