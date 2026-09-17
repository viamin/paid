# frozen_string_literal: true

# A human's resolution of a material_drift/uncertain/not_evaluated intent
# conformance verdict. See RDR-067.
#
# @spec INTENT-CONFORMANCE-004
class IntentConformanceDecision < ApplicationRecord
  FIX_PR = "fix_pr"
  BOUNDED_EXCEPTION = "bounded_exception"
  DESIGN_AMENDMENT = "design_amendment"
  ACTIONS = [ FIX_PR, BOUNDED_EXCEPTION, DESIGN_AMENDMENT ].freeze

  belongs_to :issue
  belongs_to :verdict, class_name: "IntentConformanceVerdict", optional: true
  belongs_to :actor, class_name: "User"

  validates :action, inclusion: { in: ACTIONS }
  validates :head_sha, :reason, presence: true

  scope :bounded_exceptions, -> { where(action: BOUNDED_EXCEPTION) }

  # A bounded exception is head-scoped by design: it stops applying the
  # moment a new commit changes the PR HEAD, so it can never quietly cover a
  # later, unreviewed change (@spec INTENT-CONFORMANCE-005).
  def self.active_bounded_exception?(issue:, head_sha:)
    return false if head_sha.blank?

    bounded_exceptions.exists?(issue: issue, head_sha: head_sha)
  end

  def fix_pr? = action == FIX_PR
  def bounded_exception? = action == BOUNDED_EXCEPTION
  def design_amendment? = action == DESIGN_AMENDMENT
end
