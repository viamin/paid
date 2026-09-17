# frozen_string_literal: true

# @spec INTENT-AMENDMENT-001 @spec INTENT-AMENDMENT-002
# RDR-067 human resolution of an intent-conformance decision. A one-PR
# implementation exception is structurally bounded: it can never mark an
# approved product commitment (behavior, constraints, scope, acceptance
# criteria) as changed. Product-contract changes exist only as
# design_amendment resolutions linked to a DesignAmendment, which requires
# human approval and merge before affected work resumes.
class IntentConformanceResolution < ApplicationRecord
  RESOLUTION_TYPES = %w[require_within_scope implementation_exception design_amendment].freeze
  PRODUCT_CONTRACT_FLAGS = %w[changes_behavior changes_constraints changes_scope changes_acceptance_criteria].freeze

  belongs_to :project
  belongs_to :issue
  belongs_to :design_amendment, optional: true
  belongs_to :resolved_by, class_name: "User"

  validates :resolution_type, presence: true, inclusion: { in: RESOLUTION_TYPES }
  validates :pr_head_sha, presence: true
  validates :reason, presence: true
  validates :issue_id, uniqueness: { scope: :pr_head_sha }
  validate :issue_belongs_to_project
  validate :issue_is_pull_request
  validate :amendment_required_for_design_amendment_resolution
  validate :product_contract_changes_require_amendment

  def exception? = resolution_type == "implementation_exception"
  def amendment_resolution? = resolution_type == "design_amendment"

  def product_contract_changed?
    PRODUCT_CONTRACT_FLAGS.any? { |flag| public_send(flag) }
  end

  private

  def issue_belongs_to_project
    return if issue.blank? || project.blank?
    return if issue.project_id == project_id

    errors.add(:issue, "must belong to the same project")
  end

  def issue_is_pull_request
    return if issue.blank? || issue.is_pull_request?

    errors.add(:issue, "must be a pull request")
  end

  def amendment_required_for_design_amendment_resolution
    return unless amendment_resolution?
    return if design_amendment.present?

    errors.add(:design_amendment, "must be linked when the resolution is a design amendment")
  end

  # INTENT-AMENDMENT-001: the structural bound. Any product-contract flag set
  # on a non-amendment resolution — most importantly a one-PR exception —
  # makes the record invalid. Product-contract changes are only expressible
  # as design amendments.
  def product_contract_changes_require_amendment
    return unless product_contract_changed?
    return if amendment_resolution?

    errors.add(:base, "approved product commitments can only change through a design amendment")
  end
end
