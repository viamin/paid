# frozen_string_literal: true

# Bearer credential for the /api/v1 mobile namespace (MOBILE-API segment).
# The plaintext secret exists only in the creation response; the table stores
# a deterministic SHA-256 digest so lookups stay indexed — the server never
# needs to recover the secret after issuance, only to match it.
class PersonalAccessToken < ApplicationRecord
  has_logidze

  TOKEN_PREFIX = "paid_pat_"
  SECRET_BYTES = 32
  DEFAULT_SCOPES = %w[inbox chat].freeze
  LAST_USED_THROTTLE = 5.minutes

  belongs_to :user
  belongs_to :account

  # One-time plaintext handed to the creation response. Never persisted,
  # logged, or re-derivable; #inspect strips it.
  attr_accessor :plaintext_token

  validates :name, presence: true, uniqueness: { scope: :user_id }
  validates :token_digest, presence: true, uniqueness: true
  validate :user_belongs_to_account, if: -> { user.present? }

  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }
  scope :expired, -> { where.not(expires_at: nil).where("expires_at <= ?", Time.current) }
  scope :revoked, -> { where.not(revoked_at: nil) }

  # @spec MOBILE-API-005
  def user_belongs_to_account
    return if account_id == user.account_id

    errors.add(:account, "must match the user's account")
  end

  class << self
    # @spec MOBILE-API-001
    def generate_plaintext
      "#{TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(SECRET_BYTES)}"
    end

    # @spec MOBILE-API-001
    def digest(plaintext)
      Digest::SHA256.base64digest(plaintext.to_s)
    end

    # Builds (unsaved) a token for the user with a fresh secret available via
    # #plaintext_token for the show-once creation response.
    # @spec MOBILE-API-001
    def build_for(user:, name:, expires_at: nil)
      plaintext = generate_plaintext
      new(user: user, account: user.account, name: name, token_digest: digest(plaintext),
        scopes: DEFAULT_SCOPES, expires_at: expires_at).tap do |token|
        token.plaintext_token = plaintext
      end
    end

    # @spec MOBILE-API-001
    def create_for!(user:, name:, expires_at: nil)
      build_for(user:, name:, expires_at:).tap(&:save!)
    end

    # Resolves a bearer value to an active token, or nil for unknown,
    # revoked, and expired values alike — callers cannot distinguish the
    # failure mode. The lookup runs under system access because it happens
    # before any tenant context exists (the same reason Devise controllers
    # bypass RLS), and it preloads the subject and tenant so establishing the
    # request context never depends on one.
    # @spec MOBILE-API-002
    def resolve(bearer_value)
      return nil unless bearer_value.is_a?(String) && bearer_value.start_with?(TOKEN_PREFIX)

      TenantContext.with_system_access do
        includes(:user, :account).find_by(token_digest: digest(bearer_value)).then do |token|
          next nil if token.nil? || !token.active?

          token
        end
      end
    end
  end

  def active?
    revoked_at.nil? && (expires_at.nil? || expires_at > Time.current)
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def revoked?
    revoked_at.present?
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  # Stamps the usage marker at most once per throttle window so polling
  # clients do not turn every request into a write. Feeds the revocation UI
  # and hygiene reporting only — never gates authorization.
  # @spec MOBILE-API-003
  def touch_last_used!
    return if last_used_at.present? && last_used_at > LAST_USED_THROTTLE.ago

    update_columns(last_used_at: Time.current)
  end
end
