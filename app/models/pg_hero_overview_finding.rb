# frozen_string_literal: true

# One row per stable development PgHero Overview finding identity, tracking
# observation continuity and the GitHub issue that carries it. System
# infrastructure in the primary database (like the PgHero history tables),
# not tenant-owned data.
#
# @spec RAILS-CONTROL-PLANE-027 RAILS-CONTROL-PLANE-028
class PgHeroOverviewFinding < ApplicationRecord
  self.table_name = "pghero_overview_findings"

  # Scans older than this with no observation are stale state (e.g. the
  # scanner was disabled for a long period); persistence counters should not
  # survive a gap that wide.
  STALE_AFTER = 7.days

  validates :database, :finding_key, :finding_type, presence: true
  validates :database, uniqueness: { scope: :finding_key }

  scope :stale, -> { where(arel_table[:last_seen_at].lt(STALE_AFTER.ago)) }
  scope :open_issues, -> { where.not(github_issue_number: nil).where(resolved_at: nil) }

  def tracked_issue? = github_issue_number.present? && resolved_at.nil?
end
