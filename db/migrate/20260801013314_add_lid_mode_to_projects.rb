# frozen_string_literal: true

class AddLidModeToProjects < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:projects, :lid_mode)

    add_column :projects, :lid_mode, :string
  end
end
