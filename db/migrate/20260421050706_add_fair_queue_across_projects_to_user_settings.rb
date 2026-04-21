# frozen_string_literal: true

class AddFairQueueAcrossProjectsToUserSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :user_settings, :fair_queue_across_projects, :boolean, default: true, null: false
  end
end
