# frozen_string_literal: true

# One selected repair owns any number of independently observed findings.
# @spec RAILS-CONTROL-PLANE-033 RAILS-CONTROL-PLANE-034
class PgHeroOverviewRepair < ApplicationRecord
  self.table_name = "pghero_overview_repairs"

  belongs_to :project
  has_many :findings, class_name: "PgHeroOverviewFinding", foreign_key: :repair_id,
    inverse_of: :repair, dependent: :restrict_with_exception

  validates :database, :repair_key, :title, presence: true
  validates :repair_key, uniqueness: { scope: %i[project_id database] }

  def finding_identities
    findings.order(:finding_key).map { |row| "#{row.database}/#{row.finding_key}" }
  end
end
