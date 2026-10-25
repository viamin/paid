# frozen_string_literal: true

# Bounded evidence record for one capability-aware execution validation
# generation started from a prerequisite Inbox item (#4643). The row captures
# the capability/authorization scope the validation ran against and the durable
# evidence it collected; execution itself runs through the synthetic AgentRun
# referenced by +agent_run+ (provision/execute/cleanup infrastructure reused,
# not duplicated).
#
# The validation has no closing authority: it links evidence to the
# prerequisite owner issue and never resolves the prerequisite notification,
# closes the owner, or mutates paid_state (PREREQ-EVIDENCE-006).
class PrerequisiteValidation < ApplicationRecord
  STATUSES = %w[pending running succeeded partial failed cancelled unavailable blocked].freeze
  ACTIVE_STATUSES = %w[pending running].freeze
  TERMINAL_STATUSES = %w[succeeded partial failed cancelled unavailable blocked].freeze
  TERMINAL_STATUS_CANCELLED = "cancelled"
  # Statuses that prove an execution actually ran (as opposed to never being
  # attempted for a missing capability or authorization).
  EXECUTED_STATUSES = %w[succeeded partial failed cancelled].freeze
  MAX_ANALYZER_COMMAND_LENGTH = 300
  OUTPUT_BOUND = 10_000
  # Goal of the synthetic AgentRun that carries a validation's execution
  # evidence; registered in AgentRun::GOALS so the label is truthful for the
  # persisted evidence run.
  RUN_GOAL = "validate_prerequisite"
  # Bounded, read-only default probe: `scc` is pinned in the agent image and
  # `git rev-parse HEAD` records the pinned checkout identity the analyzer
  # ran against.
  DEFAULT_ANALYZER_COMMAND = "scc --version && git rev-parse HEAD"

  belongs_to :account
  belongs_to :project
  belongs_to :issue, optional: true
  belongs_to :requested_by, class_name: "User", optional: true
  belongs_to :agent_run, optional: true

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :analyzer_command, length: { maximum: MAX_ANALYZER_COMMAND_LENGTH }, allow_nil: true
  validate :issue_belongs_to_project
  validate :analyzer_command_not_blank

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :terminal, -> { where(status: TERMINAL_STATUSES) }
  scope :latest_first, -> { order(created_at: :desc, id: :desc) }
  scope :for_issue, ->(issue) { where(issue: issue).latest_first }

  def self.open_for_issue(issue)
    active.for_issue(issue).first
  end

  def self.latest_for_issue(issue)
    for_issue(issue).first
  end

  def active? = ACTIVE_STATUSES.include?(status)
  def terminal? = TERMINAL_STATUSES.include?(status)
  def executed? = EXECUTED_STATUSES.include?(status)
  def pending? = status == "pending"
  def running? = status == "running"

  # True when this terminal validation's policy scope no longer matches the
  # supplied digest of current inputs. Stale evidence is revalidated (a new
  # generation), never presented as current (PREREQ-EVIDENCE-007).
  def stale?(current_scope_digest)
    terminal? && scope_digest.present? && scope_digest != current_scope_digest
  end

  def record_blocker!(check:, reason:, authorized_action:)
    entry = { "check" => check, "reason" => reason, "authorized_action" => authorized_action }
    update!(blockers: blockers + [ entry ])
  end

  # Conditionally transitions pending/running → running so a concurrent
  # cancellation can never be clobbered back to an executing state.
  # Returns false (and reloads) when the row is no longer active.
  def mark_running!
    now = Time.current
    updated = self.class.where(id: id, status: ACTIVE_STATUSES).update_all(status: "running", started_at: now, updated_at: now)
    return false if updated != 1

    self.status = "running"
    self.started_at = now
    true
  end

  # Completes the validation with a terminal status. Conditional on still
  # being active so a concurrent cancellation's *status* is preserved rather
  # than overwritten by a late completion — but the evidence payload still
  # lands, because cancellation must preserve collected evidence
  # (PREREQ-EVIDENCE-007).
  def complete!(status:, result: {})
    raise ArgumentError, "invalid terminal status #{status.inspect}" unless TERMINAL_STATUSES.include?(status)

    now = Time.current
    updated = self.class.where(id: id, status: ACTIVE_STATUSES)
      .update_all(status: status, result: result, completed_at: now, updated_at: now)
    if updated != 1 && status == TERMINAL_STATUS_CANCELLED
      self.class.where(id: id, status: TERMINAL_STATUS_CANCELLED)
        .update_all(result: result, completed_at: now, updated_at: now)
    end
    reload
    self
  end

  private

  def issue_belongs_to_project
    return if issue.nil? || project.nil?
    return if issue.project_id == project.id

    errors.add(:issue, "must belong to the validation's project")
  end

  def analyzer_command_not_blank
    return if analyzer_command.nil?
    return if analyzer_command.strip.present?

    errors.add(:analyzer_command, "must not be blank")
  end
end
