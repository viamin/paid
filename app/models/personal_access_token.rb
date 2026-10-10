# frozen_string_literal: true

class PersonalAccessToken < ApplicationRecord
  has_logidze
  PREFIX = "paid_pat_"
  LAST_USED_INTERVAL = 5.minutes

  belongs_to :account
  belongs_to :user

  validates :name, :token_digest, presence: true
  validates :token_digest, uniqueness: true
  validates :name, uniqueness: { scope: :user_id }
  validate :user_belongs_to_account

  def self.issue!(user:, name:, scopes: %w[inbox chat], expires_at: nil)
    plaintext = "#{PREFIX}#{SecureRandom.urlsafe_base64(32)}"
    token = create!(user:, account: user.account, name:, scopes:, expires_at:, token_digest: digest(plaintext))
    [ token, plaintext ]
  end

  def self.authenticate(plaintext)
    return unless plaintext.to_s.start_with?(PREFIX)

    TenantContext.with_system_access { find_by(token_digest: digest(plaintext)) }
  end

  def self.digest(plaintext)
    Digest::SHA256.base64digest(plaintext)
  end

  def active?
    revoked_at.nil? && (expires_at.nil? || expires_at.future?)
  end

  def allows?(scope)
    scopes.include?(scope.to_s)
  end

  def touch_last_used!
    return if last_used_at && last_used_at >= LAST_USED_INTERVAL.ago

    update_column(:last_used_at, Time.current)
  end

  private

  def user_belongs_to_account
    errors.add(:account, "must match the user account") if user && account_id != user.account_id
  end
end
