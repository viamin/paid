# frozen_string_literal: true

class PreviewSession < ApplicationRecord
  include TenantScoped

  STATUSES = %w[pending provisioning starting ready stopped failed].freeze
  ACTIVE_STATUSES = %w[pending provisioning starting ready].freeze
  LIVE_STATUSES = %w[ready].freeze
  TERMINAL_STATUSES = %w[stopped failed].freeze

  DEFAULT_TTL_SECONDS = 30.minutes.to_i
  EXPIRY_WARNING_SECONDS = 5.minutes.to_i
  TOKEN_BYTES = 32

  belongs_to :project
  belongs_to :agent_run, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  before_validation :generate_token, on: :create

  validates :token, presence: true, uniqueness: true, length: { maximum: 64 }
  validates :branch_name, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :expires_at, presence: true
  validates :project, presence: true
  validates :tunnel_port,
    numericality: { only_integer: true, greater_than: 0, less_than: 65_536 },
    allow_nil: true
  validate :agent_run_belongs_to_same_project

  scope :active, -> { where(status: ACTIVE_STATUSES).where("expires_at > ?", Time.current) }
  scope :live, -> { where(status: LIVE_STATUSES) }
  scope :non_terminal, -> { where.not(status: TERMINAL_STATUSES) }
  scope :recent, -> { order(created_at: :desc) }
  scope :for_project, ->(project) { where(project_id: project) }
  scope :expiring_before, ->(time) { where(status: ACTIVE_STATUSES).where("expires_at <= ?", time) }

  class << self
    def build_for(project:, branch_name:, created_by: nil, agent_run: nil, ttl_seconds: DEFAULT_TTL_SECONDS)
      new(
        project:,
        account: project.account,
        branch_name:,
        created_by:,
        agent_run:,
        framework: project.detected_framework,
        status: "pending",
        expires_at: ttl_seconds.to_i.seconds.from_now
      )
    end

    def find_accessible_by_token(token)
      return nil if token.blank?

      where(token:).active.live.first
    end
  end

  def active?
    ACTIVE_STATUSES.include?(status) && !expired?
  end

  def live?
    LIVE_STATUSES.include?(status)
  end

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def failed?
    status == "failed"
  end

  def stopped?
    status == "stopped"
  end

  def pending?
    status == "pending"
  end

  def provisioning?
    status == "provisioning"
  end

  def starting?
    status == "starting"
  end

  # True while the preview is advancing toward ready but not yet serving
  # traffic (queued, provisioning the container, or starting the app/tunnel).
  def in_progress?
    %w[pending provisioning starting].include?(status)
  end

  def accessible?
    live? && !expired?
  end

  def proxiable?
    accessible? && tunnel_port.present?
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def time_remaining
    return 0 if expires_at.nil? || expired?

    [ (expires_at - Time.current).to_i, 0 ].max
  end

  def ttl_warning?
    active? && time_remaining <= EXPIRY_WARNING_SECONDS
  end

  def mark_ready!(tunnel_port:, container_id: nil)
    update!(
      status: "ready",
      tunnel_port:,
      container_id: container_id || self.container_id,
      last_active_at: Time.current
    )
  end

  def mark_failed!(message)
    update!(status: "failed", error_message: message)
  end

  def mark_stopped!
    update!(status: "stopped", tunnel_port: nil)
  end

  def touch_last_active!
    update_column(:last_active_at, Time.current) if persisted?
  end

  def touch_last_accessed!
    return if last_active_at.present? && last_active_at > 1.minute.ago

    TenantContext.with_system_access { update_column(:last_active_at, Time.current) }
  rescue ActiveRecord::StatementInvalid, ActiveRecord::ActiveRecordError
    true
  end

  def proxy_prefix
    "/previews/#{token}"
  end

  def framework_label
    Projects::FrameworkProfile.label_for(framework)
  end

  STATUS_LABELS = {
    "pending" => "Queued",
    "provisioning" => "Provisioning",
    "starting" => "Starting",
    "ready" => "Ready",
    "stopped" => "Stopped",
    "failed" => "Failed"
  }.freeze

  def status_label
    STATUS_LABELS.fetch(status) { status.humanize }
  end

  def status=(value)
    super
    self.error_message = nil if value != "failed" && error_message.present?
  end

  private

  def generate_token
    self.token ||= SecureRandom.hex(TOKEN_BYTES)
  end

  def agent_run_belongs_to_same_project
    return unless agent_run && agent_run.project_id != project_id

    errors.add(:agent_run, "must belong to the same project")
  end
end
