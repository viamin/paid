# frozen_string_literal: true

class AddTokenBudgetMaxInputTokensToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :token_budget_max_input_tokens, :integer,
      comment: "Per-run input token budget; runs exceeding it without output are terminated early (nil = defer to provider/global default)"
  end
end
