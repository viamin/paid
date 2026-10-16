# frozen_string_literal: true

class ChatMessage < ApplicationRecord
  ROLES = %w[system user assistant tool].freeze
  TOOL_STATUSES = %w[pending approved denied].freeze

  before_validation :set_external_id, on: :create

  belongs_to :chat_session
  has_one :chat_diagram, dependent: :nullify
  has_many :api_usage_attempts, dependent: :nullify

  validates :role, inclusion: { in: ROLES }
  validates :content, presence: true, unless: -> { tool_result_message? || tool_name.present? }
  validates :tool_status, inclusion: { in: TOOL_STATUSES }, allow_nil: true
  validates :external_id, uniqueness: true

  scope :chronological, -> { order(created_at: :asc) }
  scope :for_conversation, -> { where(role: %w[user assistant tool]).chronological }
  scope :pending_tool_confirmations, -> { where.not(tool_status: nil).where(tool_status: "pending") }
  scope :system, -> { where(role: "system") }
  scope :container_capability_notices, -> { system.where("metadata ->> 'container_capability_notice' = 'true'") }
  scope :groupable_tools, -> {
    where(<<~SQL.squish)
      (role = 'tool' OR NULLIF(BTRIM(tool_name), '') IS NOT NULL)
      AND (tool_status IS NULL OR tool_status <> 'pending')
      AND COALESCE(metadata -> 'token_limit_error', 'false'::jsonb) <> 'true'::jsonb
      AND COALESCE(metadata -> 'rate_limit_paused', 'false'::jsonb) <> 'true'::jsonb
      AND COALESCE(metadata -> 'provider_error_notice', 'false'::jsonb) <> 'true'::jsonb
      AND COALESCE(metadata -> 'pending_confirmation_notice', 'false'::jsonb) <> 'true'::jsonb
    SQL
  }

  def pending_confirmation?
    tool_status == "pending"
  end

  def resolved_tool_confirmation?
    tool_status == "approved" || tool_status == "denied"
  end

  # A server-injected assistant message announcing a runner fallback (rate
  # limit / provider error). Excluded from the LLM conversation rebuild and
  # surfaced to clients via a dedicated event flag.
  def fallback_notice?
    metadata.is_a?(Hash) && metadata["fallback_notice"] == true
  end

  # @spec CHAT-API-016
  def display_content
    text = content.to_s
    return text unless text.start_with?("<think>")
    return "" unless text.include?("</think>")

    text.sub(/\A<think>.*?<\/think>\s*/m, "")
  end

  # @spec CHAT-API-014
  # A server-injected system message explaining that a send was rejected
  # because the chat session or account hit its configured token limit
  # (#3847). Rendered as a persistent, non-collapsed notice instead of the
  # regular collapsible system-prompt bubble.
  def token_limit_error?
    metadata.is_a?(Hash) && metadata["token_limit_error"] == true
  end

  # @spec CHAT-API-017
  # A server-injected system message explaining that the chat session was
  # paused because its runner (and every configured fallback) hit a provider
  # rate limit (#3953). Rendered as a persistent, non-collapsed notice for the
  # same reason as +token_limit_error?+.
  def rate_limit_paused?
    metadata.is_a?(Hash) && metadata["rate_limit_paused"] == true
  end

  # @spec CHAT-API-017
  # A durable, non-collapsed notice for a provider error encountered while
  # automatically resuming a previously rate-limited session.
  def provider_error_notice?
    metadata.is_a?(Hash) && metadata["provider_error_notice"] == true
  end

  # @spec PARTIAL-CLOSEOUT-017
  # Server-injected system notice persisted when the user sends a
  # conversational message while a write-tool confirmation is pending: the
  # message is not an approval and nothing has run yet. Non-collapsed so a
  # conversational "yes" can never read as an executed action.
  def pending_confirmation_notice?
    metadata.is_a?(Hash) && metadata["pending_confirmation_notice"] == true
  end

  # @spec CHAT-API-024
  def groupable_tool?
    (tool_name.present? || role == "tool") && !pending_confirmation? && !transcript_notice?
  end

  def transcript_notice?
    token_limit_error? || rate_limit_paused? || provider_error_notice? || pending_confirmation_notice?
  end

  private

  def tool_result_message?
    role == "tool"
  end

  def set_external_id
    self.external_id ||= SecureRandom.uuid
  end
end
