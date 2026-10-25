# frozen_string_literal: true

# One bounded capability-aware execution attempt that collects technical
# prerequisite evidence (for example the #4604 native-analyzer and
# tool-sidecar artifacts) through the existing AgentRun execution contract.
# The attempt persists its explicit artifact contract, the capability
# snapshot inspected at start, per-step results, and identity/cleanup
# evidence; it never mutates the prerequisite issue itself.
#
# @spec PREREQ-EXEC-006 @spec PREREQ-EXEC-011 @spec PREREQ-EXEC-012
class PrerequisiteExecutionValidation < ApplicationRecord
  ACTIVE_STATUSES = %w[pending preparing running].freeze
  TERMINAL_STATUSES = %w[succeeded partial failed cancelled unavailable].freeze
  STATUSES = (ACTIVE_STATUSES + TERMINAL_STATUSES).freeze

  NATIVE_ANALYZER_STEP = "native_analyzer"
  TOOL_SIDECAR_STEP = "tool_sidecar"
  CHECKOUT_IDENTITY_STEP = "checkout_identity"

  # The AgentRun terminal status matching each validation outcome: a
  # succeeded or partial validation finished its bounded execution, an
  # unavailable one never produced a running container, and a cancelled
  # one was stopped by an operator.
  # @spec PREREQ-EXEC-011
  AGENT_RUN_STATUS_BY_OUTCOME = {
    "succeeded" => "completed",
    "partial" => "completed",
    "failed" => "failed",
    "unavailable" => "failed",
    "cancelled" => "cancelled"
  }.freeze

  belongs_to :project
  belongs_to :issue, optional: true
  belongs_to :agent_run, optional: true
  belongs_to :initiated_by, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :branch, presence: true, length: { maximum: 255 }
  validates :scope_digest, presence: true, length: { maximum: 64 }

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :terminal, -> { where(status: TERMINAL_STATUSES) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def self.latest_for_issue(issue)
    where(issue: issue).newest_first.first
  end

  # @spec PREREQ-EXEC-011
  def self.agent_run_status_for(outcome)
    AGENT_RUN_STATUS_BY_OUTCOME.fetch(outcome, "failed")
  end

  def active?
    status.in?(ACTIVE_STATUSES)
  end

  def pending?
    status == "pending"
  end

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  def succeeded?
    status == "succeeded"
  end

  def unavailable?
    status == "unavailable"
  end

  def cancelled?
    status == "cancelled"
  end

  # @spec PREREQ-EXEC-014
  def mark_stale!
    update!(stale: true) unless stale?
  end

  def transition!(next_status)
    update!(status: next_status)
  end

  def planned_step_keys
    Array(contract["steps"]).filter_map { |step| step["key"] }
  end

  def step_result(key)
    Array(steps).find { |step| step["key"] == key }
  end

  def step_succeeded?(key)
    step_result(key)&.dig("status") == "succeeded"
  end

  def missing_requirements
    Array(capability_snapshot["missing"])
  end

  def tool_contract
    contract["tool"].presence
  end
end
