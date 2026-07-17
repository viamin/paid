# frozen_string_literal: true

# Encapsulates a single live preview of a web app running in a container.
#
# A preview session bridges a tunnel port (exposed on the Rails host by a
# rathole client running inside the preview container) to the Rails reverse
# proxy at `/previews/:token/*`. The token is the proxy credential: any holder
# of the token can view the proxied app. Tokens are therefore random secrets
# that are only handed out to authorized users by the preview UI.
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
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

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
  end

  private

  def ensure_token
    self.token ||= SecureRandom.hex(TOKEN_LENGTH)
  end

  def ensure_expires_at
    self.expires_at ||= DEFAULT_TTL_SECONDS.from_now
  end
end
