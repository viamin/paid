# frozen_string_literal: true

# @spec API-CONVERSATION-DELEGATION-002
class ApiUsageAttempt < ApplicationRecord
  STATUSES = %w[succeeded failed cancelled partial].freeze
  PRICING_SOURCES = %w[provider_reported harness_estimated historical_estimate unknown].freeze

  belongs_to :account
  belongs_to :project, optional: true
  belongs_to :agent_run, optional: true
  belongs_to :chat_session, optional: true
  belongs_to :chat_message, optional: true
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :runner, optional: true
  belongs_to :token_usage, optional: true

  validates :attempt_id, presence: true, length: { maximum: 255 }
  validates :ordinal, numericality: { only_integer: true, greater_than: 0 }
  validates :provider, presence: true, length: { maximum: 100 }
  validates :llm_model, length: { maximum: 100 }
  validates :status, inclusion: { in: STATUSES }
  validates :pricing_source, inclusion: { in: PRICING_SOURCES }
  validates :provider_currency, format: { with: /\A[A-Z]{3}\z/ }, allow_nil: true
  validates :input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validate :exactly_one_owner
  validate :usage_is_complete_or_unknown
  validate :project_belongs_to_account
  validate :chat_message_belongs_to_session

  def usage_known?
    input_tokens.present? && output_tokens.present?
  end

  def usage_unknown?
    !usage_known?
  end

  private

  def exactly_one_owner
    return if [ agent_run_id, chat_session_id ].count(&:present?) == 1

    errors.add(:base, "must belong to exactly one of agent run or chat session")
  end

  def usage_is_complete_or_unknown
    return if input_tokens.present? == output_tokens.present?

    errors.add(:base, "input and output usage must both be known or both be unknown")
  end

  def project_belongs_to_account
    return unless project && account
    return if project.account_id == account_id

    errors.add(:project, "must belong to the account")
  end

  def chat_message_belongs_to_session
    return unless chat_message && chat_session
    return if chat_message.chat_session_id == chat_session_id

    errors.add(:chat_message, "must belong to the chat session")
  end
end
