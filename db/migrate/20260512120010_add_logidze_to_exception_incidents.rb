# frozen_string_literal: true

class AddLogidzeToExceptionIncidents < ActiveRecord::Migration[8.1]
  def change
    add_column :exception_incidents, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_exception_incidents, on: :exception_incidents
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_exception_incidents" on "exception_incidents";
        SQL
      end
    end
  end
end
