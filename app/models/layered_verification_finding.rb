# frozen_string_literal: true

# A source-grounded discrepancy an audit found. Identity is
# (project, obligation, correspondence claim type, cause signature): a repeated
# audit that reproduces the same unresolved cause attaches an observation to the
# existing finding instead of creating a second Inbox entry. Two findings are
# never merged on textual similarity alone.
#
# @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
class LayeredVerificationFinding < ApplicationRecord
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation", inverse_of: :findings
  belongs_to :agent_run, optional: true, inverse_of: :findings
  belongs_to :resolved_by, class_name: "User", optional: true

  has_many :check_results, class_name: "LayeredVerificationCheckResult", foreign_key: :obligation_id,
    inverse_of: :obligation

  validates :status, inclusion: { in: STATUSES }
  validates :correspondence_claim_type, presence: true
  validates :cause_signature, presence: true
  validates :question, :observed_behavior, :limitations, presence: true
  validates :cause_signature, uniqueness: {
    scope: [ :project_id, :obligation_id, :correspondence_claim_type ],
    message: "already has a finding for this cause"
  }
  validate :obligation_belongs_to_same_project
  validate :agent_run_belongs_to_same_project, if: -> { agent_run.present? }

  def unresolved?
    status != "resolved"
  end

  def deferred?
    status == "deferred"
  end

  def observations_count
    Array(observations).size
  end

  def option_labels
    Array(options).filter_map { |option| option["label"] || option[:label] }
  end

  private

  def obligation_belongs_to_same_project
    return if obligation.project_id == project_id

    errors.add(:obligation, "must belong to the same project")
  end

  def agent_run_belongs_to_same_project
    return if agent_run.project_id == project_id

    errors.add(:agent_run, "must belong to the same project")
  end
end
