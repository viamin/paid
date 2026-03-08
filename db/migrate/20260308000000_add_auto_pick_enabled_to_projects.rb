# frozen_string_literal: true

class AddAutoPickEnabledToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :auto_pick_enabled, :boolean, default: true, null: false
  end
end
