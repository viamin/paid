# frozen_string_literal: true

class AddLogidzeToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_projects, on: :projects
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_projects" on "projects";
        SQL
      end
    end
  end
end
