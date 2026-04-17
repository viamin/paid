# frozen_string_literal: true

class AddReviewGateToPrompts < ActiveRecord::Migration[8.1]
  def change
    # When true, evolved prompt variants must be approved by a human reviewer
    # before they can be promoted to current_version. When false, evolved
    # variants auto-promote (advanced-user opt-out).
    add_column :prompts, :requires_review, :boolean, default: false, null: false
  end
end
