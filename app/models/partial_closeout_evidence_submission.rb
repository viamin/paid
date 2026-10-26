# frozen_string_literal: true

# Durable, criterion-scoped evidence offered for a partial-closeout human or
# external prerequisite. This record is deliberately not a notification state:
# a dismissal can affect scheduling, while only an assessed submission can
# speak to acceptance.
# @spec PARTIAL-CLOSEOUT-030
class PartialCloseoutEvidenceSubmission < ApplicationRecord
  STATUSES = %w[submitted sufficient insufficient stale unavailable revoked].freeze
  EVIDENCE_TYPES = %w[link artifact evaluation run report].freeze

  include TenantScoped

  belongs_to :account
  belongs_to :project
  belongs_to :issue
  belongs_to :actor, class_name: "User", optional: true

  validates :criterion, :evidence_reference, :source_revision, :explanation, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :evidence_type, inclusion: { in: EVIDENCE_TYPES }
  validate :tenant_owns_links

  private

  def tenant_owns_links
    errors.add(:project, "must belong to the evidence account") if project.present? && project.account_id != account_id
    errors.add(:issue, "must belong to the evidence project") if issue.present? && issue.project_id != project_id
    errors.add(:actor, "must belong to the evidence account") if actor.present? && actor.account_id != account_id
  end
end
