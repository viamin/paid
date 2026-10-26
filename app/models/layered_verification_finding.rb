# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-017
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true
  belongs_to :originating_audit_run, class_name: "AgentRun", optional: true

  validates :correspondence_claim_type, inclusion: { in: LayeredVerificationCorrespondenceClaim::CLAIM_TYPES }
  validates :cause_signature, format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }
  validates :status, inclusion: { in: STATUSES }
  validates :source_passages, :observed_behavior, :decision_question, presence: true
  validates :cause_signature, uniqueness: { scope: [ :project_id, :obligation_id, :correspondence_claim_type ] }
  validate :obligation_belongs_to_project

  def unresolved? = status.in?(%w[open deferred])

  def record_observation!(check_result:)
    with_lock do
      update!(observations: observations + [ {
        "check_result_id" => check_result.id,
        "observed_at" => Time.current.iso8601,
        "input_revision" => check_result.input_revision
      } ])
    end
  end

  private

  def obligation_belongs_to_project
    return if obligation&.project_id == project_id

    errors.add(:obligation, "must belong to the project")
  end
end
