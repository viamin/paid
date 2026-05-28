# frozen_string_literal: true

class RemediationDecision < ApplicationRecord
  PROPOSED_ACTIONS = %w[
    notify
    file_issue
    mark_runner_unavailable
    clear_runner_field
    disable_runner_fallback
  ].freeze
  STATUSES = %w[proposed approved applied skipped failed reverted].freeze
  OUTCOMES = %w[improved unchanged regressed].freeze

  belongs_to :account
  belongs_to :applied_by, class_name: "User", optional: true

  validates :fingerprint, presence: true
  validates :root_cause, presence: true
  validates :confidence, numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }
  validates :proposed_action, presence: true, inclusion: { in: PROPOSED_ACTIONS }
  validates :action_target_type, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true
  validates :occurrence_count, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :diagnosis_attempted_on, presence: true
  validates :diagnosis_attempt_count_on_day, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :last_diagnosis_attempt_at, presence: true
  validates :pre_remediation_failure_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :post_remediation_failure_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  def action_target_label
    case action_target_type
    when "account"
      "Account ##{action_target_id}"
    when "project"
      "Project ##{action_target_id}"
    when "runner"
      "Runner ##{action_target_id}"
    when "runner_field"
      "Runner ##{action_target_id} field #{action_target_metadata["field_name"]}"
    else
      "#{action_target_type}:#{action_target_id}"
    end
  end
end
