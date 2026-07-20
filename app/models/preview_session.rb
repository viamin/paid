# frozen_string_literal: true

<<<<<<< HEAD
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

  belongs_to :project
  belongs_to :agent_run, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  validates :token, presence: true, uniqueness: true
  validates :branch_name, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :expires_at, presence: true
  validate :agent_run_belongs_to_same_project

  # `active` filters out expired sessions so port-claim queries and the
  # `current`/status lookups cannot return a stale row whose TTL has passed
  # but which has not yet been reaped (RDR-045 review feedback). The
  # {Previews::Expire} service / reaper job eventually moves expired rows to
  # the `stopped` terminal state; this scope treats them as inactive in the
  # meantime so a follow-up start can claim a fresh port.
  scope :active, -> { where(status: ACTIVE_STATUSES).where("expires_at > ?", Time.current) }
  scope :live, -> { where(status: LIVE_STATUSES) }
  scope :non_terminal, -> { where.not(status: TERMINAL_STATUSES) }
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

  def status=(value)
    super
    self.error_message = nil if value != "failed" && error_message.present?
  end

  # Seconds remaining until the TTL deadline. Clamped at 0 once expired so the
  # UI countdown never renders negative values.
  def time_remaining
    return 0 if expires_at.nil? || expired?

    [ (expires_at - Time.current).to_i, 0 ].max
=======
# Encapsulates a single live preview of a web app running in a container.
#
# A preview session bridges a tunnel port (exposed on the Rails host by a
# rathole client running inside the preview container) to the Rails reverse
# proxy at `/previews/:token/*`. The token addresses the session's proxied path,
# but the proxy still requires an authenticated, authorized viewer before it
# forwards traffic. Tokens are therefore random secrets that are only handed out
# to authorized users by the preview UI.
#
# @see PreviewsProxy
class PreviewSession < ApplicationRecord
  STATUSES = %w[
    provisioning
    starting
    ready
    active
    expiring
    stopped
    failed
  ].freeze

  # Statuses that grant proxy access. The proxy serves traffic only while the
  # session is in one of these states and has not expired.
  ACCESSIBLE_STATUSES = %w[ready active expiring].freeze

  DEFAULT_TTL_SECONDS = 30.minutes.freeze
  TOKEN_LENGTH = 32

  belongs_to :project
  belongs_to :agent_run, optional: true

  validates :token, presence: true, uniqueness: { case_sensitive: true }, length: { maximum: 64 }
  validates :status, inclusion: { in: STATUSES }
  validates :tunnel_port, numericality: { only_integer: true, greater_than: 0, less_than: 65_536 },
    allow_nil: true
  validates :project, presence: true

  before_validation :ensure_token, on: :create
  before_validation :ensure_expires_at, on: :create

  scope :accessible, -> { where(status: ACCESSIBLE_STATUSES) }
  scope :active, -> { accessible.where("expires_at IS NULL OR expires_at > ?", Time.current) }

  class << self
    # Looks up an accessible, non-expired session by its proxy token.
    # Returns nil when the token is unknown, inactive, or expired so callers
    # can uniformly respond with a 404 and avoid leaking session existence.
    def find_accessible_by_token(token)
      return nil if token.blank?

      where(token: token).accessible.first&.tap do |session|
        return nil if session.expired?
      end
    end
  end

  def ready?
    status == "ready"
  end

  def active?
    status == "active"
  end

  # True when the session is in an accessible status and has not expired.
  def accessible?
    ACCESSIBLE_STATUSES.include?(status) && !expired?
  end

  # True when the proxy can actually serve traffic for this session: it must be
  # accessible and have an allocated tunnel port to forward to.
  def proxiable?
    accessible? && tunnel_port.present?
>>>>>>> origin/main
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

<<<<<<< HEAD
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
=======
  # Records a proxy access for idle-expiry accounting. Throttled to one write
  # per minute so a busy preview (many asset requests) does not amplify DB
  # writes. Best-effort: failures must never break a proxied response.
  #
  # Called from PreviewsProxy, which sits before ApplicationController in the
  # Rack stack and therefore has no tenant context set (bypass_tenant_rls=
  # false, current_account_id=NULL). With FORCE ROW LEVEL SECURITY on this
  # table, an un-bypassed UPDATE would match 0 rows and `last_accessed_at`
  # would silently never advance — so the write MUST run under system access,
  # mirroring how resolve_session looks up the session.
  def touch_last_accessed!
    return if last_accessed_at.present? && last_accessed_at > 1.minute.ago

    TenantContext.with_system_access { update_column(:last_accessed_at, Time.current) }
  rescue ActiveRecord::StatementInvalid, ActiveRecord::ActiveRecordError
    true
  end

  def proxy_prefix
    "/previews/#{token}"
>>>>>>> origin/main
  end

  private

<<<<<<< HEAD
  def generate_token
    self.token ||= SecureRandom.hex(TOKEN_BYTES)
  end

  def agent_run_belongs_to_same_project
    return unless agent_run && agent_run.project_id != project_id

    errors.add(:agent_run, "must belong to the same project")
=======
  def ensure_token
    self.token ||= SecureRandom.hex(TOKEN_LENGTH)
  end

  def ensure_expires_at
    self.expires_at ||= DEFAULT_TTL_SECONDS.from_now
>>>>>>> origin/main
  end
end
