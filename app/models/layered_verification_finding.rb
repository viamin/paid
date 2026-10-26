# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :agent_run

  validates :correspondence_claim_type, :cause_signature, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :records_belong_to_same_project

  def add_observation!(agent_run:, check_result_ids:)
    with_lock do
      update!(status: status == "resolved" ? "open" : status, observations: observations + [ {
        "agent_run_id" => agent_run.id,
        "check_result_ids" => check_result_ids,
        "recorded_at" => Time.current.iso8601
      } ])
    end
  end

  private

  def records_belong_to_same_project
    errors.add(:obligation, "must belong to the same project") if obligation && obligation.project_id != project_id
    errors.add(:agent_run, "must belong to the same project") if agent_run && agent_run.project_id != project_id
  end
end
