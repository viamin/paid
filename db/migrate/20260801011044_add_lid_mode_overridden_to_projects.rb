# frozen_string_literal: true

class AddLidModeOverriddenToProjects < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:projects, :lid_mode_overridden)

    add_column :projects, :lid_mode_overridden, :boolean, default: false, null: false,
      comment: "True when the project owner has manually forced lid_mode from settings. " \
        "Repo-driven detection during import/sync leaves lid_mode untouched while this is true, " \
        "until an explicit re-detect is requested."
  end
end
