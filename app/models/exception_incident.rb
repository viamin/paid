# frozen_string_literal: true

class ExceptionIncident < ApplicationRecord
  begin
    has_logidze if columns_hash.key?("log_data")
  rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid
    # Allow boot in db-less contexts and when the DB schema has not caught up yet.
  end

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

  # Incidents genuinely blocked from issue filing by the allowlist. These are
  # recorded and notified but never escalated to a GitHub issue — surfacing them
  # lets maintainers decide whether to grow the allowlist.
  #
  # Project context is required. `Handle#create_incident` initializes every
  # actionable incident as `action_taken: "notified"`, and `file_or_update_issue`
  # returns early whenever there is no project — before the allowlist is even
  # consulted. An off-allowlist incident without a project was therefore never
  # blocked by the allowlist, so including it would misreport it as a candidate
  # for allowlist expansion. Reads the allowlist constant live so dashboard
  # output tracks changes without caching.
  scope :filing_blocked, -> {
    where(action_taken: "notified")
      .where.not(subsystem: ExceptionHandler::Classifier::ISSUE_FILING_ALLOWLIST)
      .where.not(project_id: nil)
  }

  def resolved?
    status == "resolved"
  end

  # True when this incident's subsystem would be eligible for GitHub issue
  # filing. Data-driven off the live allowlist constant (no caching).
  def on_allowlist?
    ExceptionHandler::Classifier::ISSUE_FILING_ALLOWLIST.include?(subsystem)
  end

  # True when this incident was genuinely blocked from filing by the allowlist.
  # Mirrors the `filing_blocked` scope predicate so view badges stay consistent
  # with scope membership: projectless incidents are excluded because
  # `file_or_update_issue` returns early before consulting the allowlist when
  # there is no project context.
  def filing_blocked?
    action_taken == "notified" && project_id.present? && !on_allowlist?
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
