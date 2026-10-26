# frozen_string_literal: true

# @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
class LayeredVerificationFinding < ApplicationRecord
  STATES = %w[open deferred resolved].freeze

  enum :state, STATES.index_by(&:itself), validate: true

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :agent_run
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true

  validates :correspondence_claim_type, :cause_signature, :observed_behavior, :limitations, :question, presence: true
  validates :cause_signature, uniqueness: { scope: [ :project_id, :obligation_id, :correspondence_claim_type ] }
  validate :records_belong_to_project

  scope :actionable, -> { where(state: %w[open deferred]) }

  def self.record!(attributes:, observation:)
    identity = attributes.slice(:project_id, :obligation_id, :correspondence_claim_type, :cause_signature)
    transaction(requires_new: true) do
      finding = lock.find_by(identity)
      return finding.append_observation!(observation) if finding

      create!(**attributes.merge(observations: [ observation ]))
    end
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def append_observation!(observation)
    with_lock { update!(observations: observations + [ observation ]) }
    self
  end

  def defer!(reason:)
    update!(state: "deferred", deferred_reason: reason)
  end

  private

  def records_belong_to_project
    errors.add(:obligation, "must belong to the same project") if obligation && obligation.project_id != project_id
    errors.add(:agent_run, "must belong to the same project") if agent_run && agent_run.project_id != project_id
  end
end
