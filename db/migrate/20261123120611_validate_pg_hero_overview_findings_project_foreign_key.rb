class ValidatePgHeroOverviewFindingsProjectForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :pghero_overview_findings, :projects
  end
end
