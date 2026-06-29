# frozen_string_literal: true

class AddLogidzeToRunnerCredentials < ActiveRecord::Migration[8.1]
  def change
    add_column :runner_credentials, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_runner_credentials, on: :runner_credentials
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_runner_credentials" on "runner_credentials";
        SQL
      end
    end
  end
end
