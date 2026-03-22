# frozen_string_literal: true

class CreateLlmModels < ActiveRecord::Migration[8.1]
  def change
    create_table :llm_models do |t|
      t.string :model_id, null: false
      t.string :display_name, null: false
      t.string :provider, limit: 50, null: false
      t.string :family, limit: 100
      t.string :category, limit: 50, default: "general", null: false
      t.integer :context_window
      t.integer :max_output_tokens
      t.decimal :input_cost_per_million, precision: 10, scale: 4
      t.decimal :output_cost_per_million, precision: 10, scale: 4
      t.boolean :supports_vision, default: false, null: false
      t.boolean :supports_tools, default: false, null: false
      t.boolean :supports_json_output, default: false, null: false
      t.decimal :capability_score, precision: 4, scale: 2
      t.boolean :active, default: true, null: false
      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :llm_models, :model_id, unique: true
    add_index :llm_models, :provider
    add_index :llm_models, :active
    add_index :llm_models, :category
    add_index :llm_models, [ :provider, :active ]
  end
end
