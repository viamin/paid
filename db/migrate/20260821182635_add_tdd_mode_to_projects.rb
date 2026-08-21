# frozen_string_literal: true

# Adds the project-level TDD mode setting from RDR-056. Existing projects
# backfill to "off" via the column default so the migration is a no-op for
# pre-existing rows and the new column accepts only the three values from
# Project::TDD_MODES at the application layer.
class AddTddModeToProjects < ActiveRecord::Migration[8.1]
  TDD_MODE_DEFAULT = "off"

  def change
    return if column_exists?(:projects, :tdd_mode)

    add_column :projects, :tdd_mode, :string,
      default: TDD_MODE_DEFAULT,
      null: false,
      comment: "Project-level TDD mode from RDR-056: off | non_strict | strict"
  end
end
