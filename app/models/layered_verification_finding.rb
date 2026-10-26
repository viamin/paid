# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-017
  STATUSES = %w[unresolved deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :agent_run

  validates :status, inclusion: { in: STATUSES }
  validates :obligation_external_identity, :correspondence_claim_type, :cause_signature, :observed_behavior, :question, presence: true
  validate :records_share_project

  def self.record_observation!(attributes)
    finding = find_or_initialize_by(identity(attributes))
    finding.assign_attributes(attributes.except(:project, :obligation, :agent_run)) if finding.new_record?
    finding.assign_attributes(project: attributes.fetch(:project), obligation: attributes.fetch(:obligation), agent_run: attributes.fetch(:agent_run))
    finding.observations_count += 1 unless finding.new_record?
    finding.save!
    finding
  end

  private

  def self.identity(attributes)
    { project: attributes.fetch(:project), obligation_external_identity: attributes.fetch(:obligation).external_identity,
      correspondence_claim_type: attributes.fetch(:correspondence_claim_type), cause_signature: attributes.fetch(:cause_signature) }
  end

  def records_share_project
    errors.add(:obligation, "must belong to the same project") if obligation && obligation.project_id != project_id
    errors.add(:agent_run, "must belong to the same project") if agent_run && agent_run.project_id != project_id
  end
end
