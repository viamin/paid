# frozen_string_literal: true

# @spec INTENT-AMENDMENT-003 @spec INTENT-CONFORMANCE-REVIEW-001
# Minimal RDR-066 feature intent substrate for the RDR-067 amendment and
# conformance-review flows: links a feature's issue tree to its approved
# design revision and the repository paths (RDR plus required LID artifacts)
# that constitute that design (+design_document_paths+), read by
# IntentConformance::ReviewRun (#3866) at the exact +approved_design_revision+.
# The full approval lifecycle (#3862) extends this record; this slice only
# needs the released/revising transitions a design amendment drives.
class FeatureIntent < ApplicationRecord
  STATUSES = %w[
    discovering
    design_open
    needs_decision
    ready_for_approval
    approved_waiting_for_merge
    released
    revising
    cancelled
  ].freeze

  belongs_to :project

  has_many :feature_intent_issues, dependent: :destroy
  has_many :issues, through: :feature_intent_issues
  has_many :design_amendments, dependent: :restrict_with_error

  validates :title, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :released, -> { where(status: "released") }

  def released? = status == "released"
  def revising? = status == "revising"

  # Enters `revising` when a design amendment opens. Guarded so only a
  # released feature (an approved baseline exists to amend) can start one.
  def revise!
    transition_to!("revising", from: %w[released])
  end

  # Returns to `released` when the amendment merges (new revision recorded)
  # or is abandoned (prior revision stands).
  def release!
    transition_to!("released", from: %w[revising released])
  end

  private

  def transition_to!(next_status, from:)
    raise InvalidTransitionError, "cannot move feature intent from #{status} to #{next_status}" unless status.in?(from)

    update!(status: next_status)
  end

  # Raised when an amendment flow requests a lifecycle move the feature's
  # current state does not allow (e.g. amending a feature that was never
  # released).
  class InvalidTransitionError < StandardError; end
end
