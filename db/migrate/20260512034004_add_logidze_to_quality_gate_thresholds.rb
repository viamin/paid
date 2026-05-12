# frozen_string_literal: true

class AddLogidzeToQualityGateThresholds < ActiveRecord::Migration[8.1]
  def change
    add_column :quality_gate_thresholds, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_quality_gate_thresholds, on: :quality_gate_thresholds
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_quality_gate_thresholds" on "quality_gate_thresholds";
        SQL
      end
    end
  end
end
