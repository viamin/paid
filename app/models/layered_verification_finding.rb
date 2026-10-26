# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true
  belongs_to :agent_run

  validates :cause_signature, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :records_belong_to_project

  def record_observation!(agent_run:, observation:)
    with_lock do
      update!(
        agent_run:,
        observation_history: observation_history + [ observation.deep_stringify_keys.merge("recorded_at" => Time.current.iso8601) ]
      )
    end
  end

  private

  def records_belong_to_project
    errors.add(:obligation, "must belong to the same project") if obligation && obligation.project_id != project_id
    errors.add(:agent_run, "must belong to the same project") if agent_run && agent_run.project_id != project_id
    return unless correspondence_claim && correspondence_claim.obligation_id != obligation_id

    errors.add(:correspondence_claim, "must belong to the finding obligation")
  end
end
