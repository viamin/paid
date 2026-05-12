# frozen_string_literal: true

class AddLogidzeToQualityThresholds < ActiveRecord::Migration[8.1]
  def change
    add_column :quality_thresholds, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_quality_thresholds, on: :quality_thresholds
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_quality_thresholds" on "quality_thresholds";
        SQL
      end
    end
  end
end
