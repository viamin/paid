# frozen_string_literal: true

class ExceptionIncident < ApplicationRecord
  belongs_to :account
  belongs_to :project, optional: true

  SUBSYSTEMS = %w[knowledge agent_runs github_sync container_manager secrets_proxy general].freeze
  SEVERITIES = %w[p1 p2].freeze
  ACTIONS = %w[logged notified issue_filed].freeze
  STATUSES = %w[open resolved].freeze

  validates :fingerprint, presence: true, uniqueness: { scope: :account_id }
  validates :exception_class, presence: true
  validates :message, presence: true
  validates :subsystem, presence: true, inclusion: { in: SUBSYSTEMS }
  validates :severity, presence: true, inclusion: { in: SEVERITIES }
  validates :action_taken, presence: true, inclusion: { in: ACTIONS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :last_occurred_at, presence: true

  scope :open_incidents, -> { where(status: "open") }
  scope :for_subsystem, ->(subsystem) { where(subsystem: subsystem) }
  scope :by_severity, ->(severity) { where(severity: severity) }
  scope :recent, -> { order(last_occurred_at: :desc) }

  def resolved?
    status == "resolved"
  end

  def record_occurrence!(new_context: {})
    self.occurrence_count += 1
    self.last_occurred_at = Time.current
    self.context = context.merge("latest_occurrence" => new_context) if new_context.present?
    save!
  end
end
