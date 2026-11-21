# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :agent_run

  before_validation :copy_obligation_external_identity

  validates :obligation_external_identity, :correspondence_claim_type, :cause_signature, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :records_belong_to_same_project

  after_commit :bump_inbox_cache_version, if: :inbox_visibility_changed?

  def add_observation!(obligation:, agent_run:, check_result_ids:, evidence:)
    with_lock do
      next true if observation_recorded?(agent_run, check_result_ids)

      update!(
        obligation:, agent_run:,
        status: status == "resolved" ? "open" : status,
        **evidence,
        observations: observations + [ {
          "agent_run_id" => agent_run.id,
          "check_result_ids" => check_result_ids,
          "recorded_at" => Time.current.iso8601
        } ]
      )
    end
  end

  private

  def observation_recorded?(agent_run, check_result_ids)
    result_ids = Array(check_result_ids).map(&:to_s).uniq.sort
    observations.any? do |observation|
      observation.is_a?(Hash) && observation["agent_run_id"].to_s == agent_run.id.to_s &&
        Array(observation["check_result_ids"]).map(&:to_s).uniq.sort == result_ids
    end
  end

  def copy_obligation_external_identity
    self.obligation_external_identity = obligation.external_identity if obligation
  end

  def records_belong_to_same_project
    errors.add(:obligation, "must belong to the same project") if obligation && obligation.project_id != project_id
    errors.add(:agent_run, "must belong to the same project") if agent_run && agent_run.project_id != project_id
  end

  def inbox_visibility_changed?
    return status.in?(%w[open deferred]) if previously_new_record?

    saved_change_to_status? && (status_before_last_save.in?(%w[open deferred]) || status.in?(%w[open deferred]))
  end

  def bump_inbox_cache_version
    Dashboard::CacheVersion.bump(project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
  end
end
