# frozen_string_literal: true

class AddPrAutoContinueTokenLimitToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :max_pr_auto_continue_tokens, :integer,
      default: 50_000_000,
      null: false,
      comment: "Maximum recorded tokens automatic PR automation may spend on one pull request before escalation pauses follow-ups."
  end
end
