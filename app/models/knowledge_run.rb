# frozen_string_literal: true

class KnowledgeRun < ApplicationRecord
  STATUSES = %w[pending running completed failed].freeze
  ACTIVE_STATUSES = %w[pending running].freeze
  OPERATION_TYPES = %w[embedding decision_drafting].freeze
  TOKEN_LIMIT_STATUSES = AgentRun::TOKEN_LIMIT_STATUSES
  DEFAULT_MAX_TOKENS_PER_RUN = 10_000

  belongs_to :project
  has_many :token_usages, dependent: :destroy

  before_create :generate_proxy_token

  validates :operation_type, presence: true, inclusion: { in: OPERATION_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :token_limit_status, inclusion: { in: TOKEN_LIMIT_STATUSES }, allow_nil: true
  validates :final_provider, length: { maximum: 50 }
  validates :max_tokens, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :total_tokens, numericality: { greater_than_or_equal_to: 0 }

  scope :active, -> { where(status: ACTIVE_STATUSES) }

  def active?
    ACTIVE_STATUSES.include?(status)
  end

  def effective_max_tokens_per_run
    max_tokens || DEFAULT_MAX_TOKENS_PER_RUN
  end

  def record_provider_attempt(provider)
    attempt = {
      "provider" => provider,
      "attempted_at" => Time.current.iso8601
    }
    update!(provider_attempts: provider_attempts + [ attempt ])
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

  private

  def generate_proxy_token
    self.proxy_token ||= SecureRandom.hex(32)
  end
end
