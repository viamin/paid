# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-017
  STATES = %w[unresolved deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true
  belongs_to :agent_run, optional: true

  validates :correspondence_claim_type, :cause_signature, :observed_behavior, :check_limitations, :decision_question, presence: true
  validates :state, inclusion: { in: STATES }
  validates :cause_signature, format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }
  validates :cause_signature, uniqueness: { scope: [ :project_id, :obligation_id, :correspondence_claim_type ] }
  validate :obligation_belongs_to_project
  validate :claim_belongs_to_obligation

  def record_observation!(check_result:, observed_at: Time.current)
    with_lock do
      update!(
        observations: observations + [ { "check_result_id" => check_result.id, "observed_at" => observed_at.iso8601 } ],
        last_observed_at: observed_at,
        agent_run: check_result.agent_run
      )
    end
  end

  private

  def obligation_belongs_to_project
    errors.add(:obligation, "must belong to the same project") if obligation && obligation.project_id != project_id
  end

  def claim_belongs_to_obligation
    return unless correspondence_claim && correspondence_claim.obligation_id != obligation_id

    errors.add(:correspondence_claim, "must belong to the finding obligation")
  end
end
