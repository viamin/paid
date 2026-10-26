# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-015
  # @spec LAYERED-VERIFY-016
  # @spec LAYERED-VERIFY-017
  STATES = %w[unresolved deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation", inverse_of: :findings
  belongs_to :originating_audit_run, class_name: "AgentRun", optional: true

  validates :correspondence_claim_type, inclusion: { in: LayeredVerificationCorrespondenceClaim::CLAIM_TYPES }, allow_nil: true
  validates :cause_signature, :question, :check_limitations, presence: true
  validates :state, inclusion: { in: STATES }
  validate :obligation_belongs_to_project
  validate :audit_run_belongs_to_project, if: -> { originating_audit_run.present? }

  def self.record!(project:, obligation:, correspondence_claim_type:, cause_signature:, **attributes)
    transaction do
      observation = attributes.delete(:observation)
      finding = lock.where(project:, obligation:, correspondence_claim_type:, cause_signature:)
        .where.not(state: "resolved").first
      return finding.tap { |record| record.append_observation!(observation) } if finding

      create!(project:, obligation:, correspondence_claim_type:, cause_signature:, observations: [ observation ].compact, **attributes)
    end
  end

  def append_observation!(observation)
    return if observation.blank?

    update!(observations: Array(observations) + [ observation.deep_stringify_keys ])
  end

  private

  def obligation_belongs_to_project
    errors.add(:obligation, "must belong to the same project") unless obligation&.project_id == project_id
  end

  def audit_run_belongs_to_project
    return if originating_audit_run.project_id == project_id

    errors.add(:originating_audit_run, "must belong to the same project")
  end
end
