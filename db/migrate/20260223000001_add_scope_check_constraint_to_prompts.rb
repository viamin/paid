# frozen_string_literal: true

class AddScopeCheckConstraintToPrompts < ActiveRecord::Migration[8.1]
  def change
    # Enforce valid scope combinations:
    # - Global: both account_id and project_id are NULL
    # - Account-level: account_id NOT NULL, project_id NULL
    # - Project-level: both account_id and project_id NOT NULL
    # Prevents invalid state where project_id is set but account_id is NULL
    add_check_constraint :prompts,
      "(project_id IS NULL OR account_id IS NOT NULL)",
      name: "chk_prompts_scope_consistency"
  end
end
