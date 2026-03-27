# frozen_string_literal: true

class IntegrationCredential < ApplicationRecord
  AUTH_KINDS = %w[api_key oauth_token signing_token].freeze

  belongs_to :account
  belongs_to :created_by, class_name: "User", optional: true

  encrypts :secret

  validates :name, presence: true, uniqueness: { scope: %i[account_id service_key] }
  validates :service_key, presence: true
  validates :category, presence: true
  validates :auth_kind, presence: true, inclusion: { in: AUTH_KINDS }
  validates :secret, presence: true
  validate :service_key_supported
  validate :auth_kind_supported_for_service
  validate :created_by_belongs_to_same_account, if: -> { created_by.present? }

  before_validation :assign_category_from_service

  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }
  scope :revoked, -> { where.not(revoked_at: nil) }
  scope :for_category, ->(category) { where(category: category.to_s) }
  scope :for_service, ->(service_key) { where(service_key: service_key.to_s) }

  def active?
    revoked_at.nil? && (expires_at.nil? || expires_at > Time.current)
  end

  def revoked?
    revoked_at.present?
  end

  def expired?
    !revoked? && expires_at.present? && expires_at <= Time.current
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def service_definition
    Integrations::CredentialCatalog.lookup(service_key)
  end

  private

  def assign_category_from_service
    definition = Integrations::CredentialCatalog.lookup(service_key)
    self.category = definition[:category].to_s if definition
  end

  def service_key_supported
    return if service_key.blank?
    return if Integrations::CredentialCatalog.lookup(service_key)

    errors.add(:service_key, "is not supported")
  end

  def auth_kind_supported_for_service
    definition = Integrations::CredentialCatalog.lookup(service_key)
    return unless definition
    return if definition[:auth_kinds].include?(auth_kind)

    errors.add(:auth_kind, "is not supported for #{definition[:label]}")
  end

  def created_by_belongs_to_same_account
    return if created_by.account_id == account_id

    errors.add(:created_by, "must belong to the same account")
  end
end
