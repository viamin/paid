# frozen_string_literal: true

class AddLogidzeToPreCommitRequirements < ActiveRecord::Migration[8.1]
  def change
    add_column :pre_commit_requirements, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_pre_commit_requirements, on: :pre_commit_requirements
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_pre_commit_requirements" on "pre_commit_requirements";
        SQL
      end
    end
  end
end
