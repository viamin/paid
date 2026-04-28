# frozen_string_literal: true

class ChatSession < ApplicationRecord
  include TenantScoped

  STATUSES = %w[active idle closed archived].freeze
  MODES = %w[api workspace].freeze
  IDLE_TIMEOUT_DURATION = 30.minutes

  before_validation :set_external_id, on: :create

  belongs_to :project, optional: true
  belongs_to :provider, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  has_many :messages, class_name: "ChatMessage", dependent: :destroy
  has_many :chat_session_projects, dependent: :destroy
  has_many :projects, through: :chat_session_projects

  validates :status, inclusion: { in: STATUSES }
  validates :mode, inclusion: { in: MODES }
  validates :external_id, uniqueness: true
  validate :provider_must_belong_to_same_account

  scope :active, -> { where(status: "active") }
  scope :idle_expired, -> { where(status: "active").where("idle_timeout_at < ?", Time.current) }

  private

  def set_external_id
    self.external_id ||= SecureRandom.uuid
  end

  def provider_must_belong_to_same_account
    return unless provider && account

    provider_account_id = provider.user&.account_id
    return if provider_account_id == account_id

    errors.add(:provider, "must belong to the same account")
  end
end
