# frozen_string_literal: true

class AddTechnicalMergeBlockersToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :technical_merge_blockers, :jsonb, default: [], null: false,
      comment: "Bounded internal technical merge stops; independent of human-intervention labels."
  end
end
