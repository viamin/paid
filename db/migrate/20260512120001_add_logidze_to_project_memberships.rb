# frozen_string_literal: true

class AddLogidzeToProjectMemberships < ActiveRecord::Migration[8.1]
  def change
    add_column :project_memberships, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_project_memberships, on: :project_memberships
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_project_memberships" on "project_memberships";
        SQL
      end
    end
  end
end
