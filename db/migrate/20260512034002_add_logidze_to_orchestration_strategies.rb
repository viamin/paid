# frozen_string_literal: true

class AddLogidzeToOrchestrationStrategies < ActiveRecord::Migration[8.1]
  def change
    add_column :orchestration_strategies, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_orchestration_strategies, on: :orchestration_strategies
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_orchestration_strategies" on "orchestration_strategies";
        SQL
      end
    end
  end
end
