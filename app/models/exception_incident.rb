# frozen_string_literal: true

class ExceptionIncident < ApplicationRecord
  has_logidze
  belongs_to :account
  belongs_to :project, optional: true

  SUBSYSTEMS = %w[knowledge agent_runs github_sync container_manager secrets_proxy general].freeze
  SEVERITIES = %w[p1 p2].freeze
  ACTIONS = %w[logged notified filing issue_filed].freeze
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
    now = Time.current
    updates = [
      "occurrence_count = occurrence_count + 1",
      sanitize_sql([ "last_occurred_at = ?", now ]),
      sanitize_sql([ "updated_at = ?", now ])
    ]
    if new_context.present?
      merged = context.merge("latest_occurrence" => new_context)
      updates << sanitize_sql([ "context = ?::jsonb", merged.to_json ])
    end
    updates << sanitize_sql([ "status = ?", "open" ])
    updates << "resolved_at = NULL"
    self.class.where(id: id).update_all(updates.join(", "))
    reload
  end

  private

  def sanitize_sql(args)
    self.class.sanitize_sql_array(args)
  end
end
