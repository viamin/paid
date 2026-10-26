# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-017
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :agent_run

  validates :correspondence_claim_type, inclusion: { in: LayeredVerificationCorrespondenceClaim::CLAIM_TYPES }
  validates :cause_signature, format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }
  validates :status, inclusion: { in: STATUSES }
  validates :observed_behavior, :check_limitations, :question, presence: true
  validate :same_project

  def self.record!(agent_run:, obligation:, correspondence_claim_type:, cause_signature:, attributes:, check_result:)
    finding = where(project: obligation.project, obligation:, correspondence_claim_type:, cause_signature:, status: "open").first_or_initialize
    finding.assign_attributes(attributes.merge(agent_run:)) if finding.new_record?
    finding.observations = Array(finding.observations) + [ observation(check_result) ]
    finding.save!
    finding
  end

  def self.observation(check_result)
    { "recorded_at" => Time.current.iso8601, "check_result_id" => check_result.id,
      "input_revision" => check_result.input_revision }
  end
  private_class_method :observation

  private

  def same_project
    errors.add(:obligation, "must belong to the same project") if obligation && obligation.project_id != project_id
    errors.add(:agent_run, "must belong to the same project") if agent_run && agent_run.project_id != project_id
  end
end
