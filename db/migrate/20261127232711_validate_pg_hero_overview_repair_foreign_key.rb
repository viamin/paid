# frozen_string_literal: true

class ValidatePgHeroOverviewRepairForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :pghero_overview_repairs, :projects
    validate_foreign_key :pghero_overview_findings, :pghero_overview_repairs, column: :repair_id
  end
end
