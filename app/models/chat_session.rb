# frozen_string_literal: true

class ChatSession < ApplicationRecord
  include TenantScoped

  STATUSES = %w[active idle closed archived].freeze
  MODES = %w[api workspace].freeze
  IDLE_TIMEOUT_DURATION = 30.minutes

  before_validation :set_external_id, on: :create
  before_create :generate_proxy_token

  belongs_to :project, optional: true
  belongs_to :provider, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  has_many :messages, class_name: "ChatMessage", dependent: :destroy
  has_many :token_usages, dependent: :destroy
  has_many :chat_session_projects, dependent: :destroy
  has_many :projects, through: :chat_session_projects

  validates :status, inclusion: { in: STATUSES }
  validates :mode, inclusion: { in: MODES }
  validates :external_id, uniqueness: true
  validate :provider_must_belong_to_same_account
  validate :project_must_belong_to_same_account

  scope :active, -> { where(status: "active") }
  scope :idle_expired, -> { where(status: "active").where("idle_timeout_at < ?", Time.current) }

  def active?
    status == "active"
  end

  def ensure_proxy_token!
    return proxy_token if proxy_token.present?

    token = SecureRandom.hex(32)
    updated_rows = self.class.where(id: id, proxy_token: nil).update_all(proxy_token: token)

    if updated_rows == 1
      self.proxy_token = token
    else
      reload
    end

    proxy_token
  end

  def total_tokens_input
    token_usages.sum(:input_tokens)
  end

  def total_tokens_output
    token_usages.sum(:output_tokens)
  end

  def total_tokens
    token_usages.sum(Arel.sql("input_tokens + output_tokens"))
  end

  def estimated_cost_cents
    token_usages.sum(:cost_cents)
  end

  private

  def set_external_id
    self.external_id ||= SecureRandom.uuid
  end

  def generate_proxy_token
    self.proxy_token ||= SecureRandom.hex(32)
  end

  def provider_must_belong_to_same_account
    return unless provider && account

    provider_account_id = provider.user&.account_id
    return if provider_account_id == account_id

    errors.add(:provider, "must belong to the same account")
  end

  def project_must_belong_to_same_account
    return unless project && account

    return if project.account_id == account_id

    errors.add(:project, "must belong to the same account")
  end
end
