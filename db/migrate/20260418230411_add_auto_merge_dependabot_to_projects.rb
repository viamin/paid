# frozen_string_literal: true

class AddAutoMergeDependabotToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :auto_merge_dependabot, :boolean, default: false, null: false
  end
end
