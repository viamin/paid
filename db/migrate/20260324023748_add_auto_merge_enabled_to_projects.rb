# frozen_string_literal: true

class AddAutoMergeEnabledToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :auto_merge_enabled, :boolean, default: false, null: false
  end
end
