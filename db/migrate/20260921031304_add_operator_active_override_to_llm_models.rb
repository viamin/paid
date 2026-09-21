# frozen_string_literal: true

class AddOperatorActiveOverrideToLlmModels < ActiveRecord::Migration[8.1]
  def change
    add_column :llm_models, :operator_active_override, :boolean,
      comment: "Explicit operator active/inactive decision. When set, scheduled catalog " \
        "sync must preserve this value instead of reapplying the snapshot default."
  end
end
