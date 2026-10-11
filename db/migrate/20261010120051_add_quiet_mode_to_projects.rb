# frozen_string_literal: true

class AddQuietModeToProjects < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:projects, :quiet_mode)

    add_column :projects, :quiet_mode, :boolean, default: false, null: false,
      comment: "When true, Paid suppresses all issue/PR comment posting for this project (PR description writes are unaffected)."
  end
end
