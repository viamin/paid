# frozen_string_literal: true

class PreviewSession < ApplicationRecord
  include TenantScoped

  # Lifecycle states (RDR-045). `pending` is the initial DB state before the
  # provisioning service begins work; `provisioning`/`starting` are transient
  # phases; `ready` means the tunnel is up and the proxy can serve the app;
  # `stopped` and `failed` are terminal.
  STATUSES = %w[pending provisioning starting ready stopped failed].freeze
  ACTIVE_STATUSES = %w[pending provisioning starting ready].freeze
  LIVE_STATUSES = %w[ready].freeze
  TERMINAL_STATUSES = %w[stopped failed].freeze

  # Default TTL for a preview before it is auto-stopped and cleaned up.
  DEFAULT_TTL_SECONDS = 30.minutes.to_i
  # Show the TTL warning state when this much time (or less) remains.
  EXPIRY_WARNING_SECONDS = 5.minutes.to_i
  TOKEN_BYTES = 32

  before_validation :generate_token, on: :create
  before_validation :set_default_expires_at, on: :create

  belongs_to :project
  belongs_to :agent_run, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  validates :token, presence: true, uniqueness: true
  validates :branch_name, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :expires_at, presence: true
  validate :agent_run_belongs_to_same_project

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :live, -> { where(status: LIVE_STATUSES) }
  scope :recent, -> { order(created_at: :desc) }
  scope :for_project, ->(project) { where(project_id: project) }
  scope :expiring_before, ->(time) { where(status: ACTIVE_STATUSES).where("expires_at <= ?", time) }

  def self.build_for(project:, branch_name:, created_by: nil, agent_run: nil, ttl_seconds: DEFAULT_TTL_SECONDS)
    new(
      project: project,
      account: project.account,
      branch_name: branch_name,
      created_by: created_by,
      agent_run: agent_run,
      framework: project.detected_framework,
      status: "pending",
      expires_at: ttl_seconds.to_i.seconds.from_now
    )
  end

  def active?
    ACTIVE_STATUSES.include?(status)
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

  def status=(value)
    super
    self.error_message = nil if value != "failed" && error_message.present?
  end

  # Seconds remaining until the TTL deadline. Clamped at 0 once expired so the
  # UI countdown never renders negative values.
  def time_remaining
    return 0 if expires_at.nil? || expired?

    [(expires_at - Time.current).to_i, 0].max
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  # True when the TTL is close enough to warrant the warning UI state, and only
  # meaningful while the preview is still active.
  def ttl_warning?
    active? && time_remaining <= EXPIRY_WARNING_SECONDS
  end

  def mark_ready!(tunnel_port:, container_id: nil)
    update!(status: "ready", tunnel_port: tunnel_port, container_id: container_id || self.container_id,
            last_active_at: Time.current)
  end

  def mark_failed!(message)
    update!(status: "failed", error_message: message)
  end

  def mark_stopped!
    update!(status: "stopped")
  end

  def touch_last_active!
    update_column(:last_active_at, Time.current) if persisted?
  end

  private

  def generate_token
    self.token ||= SecureRandom.hex(TOKEN_BYTES)
  end

  def set_default_expires_at
    self.expires_at ||= DEFAULT_TTL_SECONDS.seconds.from_now
  end

  def agent_run_belongs_to_same_project
    return unless agent_run && agent_run.project_id != project_id

    errors.add(:agent_run, "must belong to the same project")
  end
end
