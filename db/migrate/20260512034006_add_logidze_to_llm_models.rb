# frozen_string_literal: true

class AddLogidzeToLlmModels < ActiveRecord::Migration[8.1]
  def change
    add_column :llm_models, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_llm_models, on: :llm_models
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_llm_models" on "llm_models";
        SQL
      end
    end
  end
end
