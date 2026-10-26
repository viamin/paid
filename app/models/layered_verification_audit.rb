# frozen_string_literal: true

# One bounded audit of a project's business obligations. The audit is the
# run record: it carries the resolved scope, the sources and revision the
# checks are bound to, the budget, the provenance of the request, progress,
# waiting reasons, cancellation, and the synthesized report.
#
# @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-020
class LayeredVerificationAudit < ApplicationRecord
  STATUSES = %w[planned dispatched running completed failed cancelled].freeze
  TRIGGER_TYPES = %w[manual_ui manual_chat manual_mcp pull_request scheduled].freeze
  TERMINAL_STATUSES = %w[completed failed cancelled].freeze

  belongs_to :project
  belongs_to :agent_run, optional: true
  belongs_to :initiating_user, class_name: "User", optional: true

  has_many :findings, class_name: "LayeredVerificationFinding", foreign_key: :agent_run_id,
    inverse_of: :agent_run, dependent: :nullify
  has_many :review_packages, class_name: "LayeredVerificationReviewPackage", foreign_key: :agent_run_id,
    inverse_of: :agent_run, dependent: :destroy

  validates :trigger_type, inclusion: { in: TRIGGER_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :scope_description, presence: true
  validate :agent_run_belongs_to_same_project

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  def coverage
    Array(report["coverage"])
  end

  def business_intent_validation
    Array(report["business_intent_validation"])
  end

  def verification_coverage
    Array(report["verification_coverage"])
  end

  def cancelled?
    status == "cancelled"
  end

  private

  def agent_run_belongs_to_same_project
    return unless agent_run
    return if agent_run.project_id == project_id

    errors.add(:agent_run, "must belong to the same project")
  end
end
