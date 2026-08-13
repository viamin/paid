# frozen_string_literal: true

class AddLogidzeToTrackerConfigurations < ActiveRecord::Migration[8.1]
  def change
    add_column :tracker_configurations, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_tracker_configurations, on: :tracker_configurations
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_tracker_configurations" on "tracker_configurations";
        SQL
      end
    end
  end
end
