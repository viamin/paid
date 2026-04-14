# frozen_string_literal: true

class AddKnowledgeRunToTokenUsages < ActiveRecord::Migration[8.1]
  def change
    add_reference :token_usages, :knowledge_run, null: true, foreign_key: { on_delete: :cascade }
    change_column_null :token_usages, :agent_run_id, true

    add_check_constraint :token_usages,
      "(agent_run_id IS NOT NULL) <> (knowledge_run_id IS NOT NULL)",
      name: "token_usages_exactly_one_run"
  end
end
