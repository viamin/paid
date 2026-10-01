# frozen_string_literal: true

module ChatSessions
  # Persists one harness-reported provider attempt before updating Paid's
  # billable usage ledger. The unique harness identity makes retry delivery and
  # recovery safe without treating absent provider usage as zero.
  class RecordTransportAttempt
    def initialize(chat_session:, actor:, message:, report:)
      @chat_session = chat_session
      @actor = actor
      @message = message
      @report = report.to_h.deep_symbolize_keys
    end

    def self.call(...)
      new(...).call
    end

    def call
      ApiUsageAttempt.transaction do
        attempt = find_or_create_attempt
        record_billable_usage(attempt)
        attempt
      end
    end

    private

    attr_reader :chat_session, :actor, :message, :report

    def find_or_create_attempt
      ApiUsageAttempt.create_with(attempt_attributes).create_or_find_by!(attempt_id: report.fetch(:attempt_id))
    end

    def attempt_attributes
      {
        account: chat_session.account,
        project: chat_session.project || raise(ArgumentError, "chat session project is required"),
        chat_session: chat_session,
        chat_message: message,
        actor: actor,
        runner: chat_session.runner,
        ordinal: report.fetch(:number),
        provider: report.fetch(:provider),
        llm_model: report[:model],
        status: report.fetch(:status),
        input_tokens: usage[:input_tokens],
        output_tokens: usage[:output_tokens],
        cache_read_tokens: usage[:cache_read_tokens],
        cache_write_tokens: usage[:cache_write_tokens],
        provider_cost_amount: provider_cost[:amount],
        provider_currency: provider_cost[:currency],
        pricing_source: pricing_source,
        provider_priced_at: provider_cost[:priced_at],
        started_at: report.fetch(:started_at),
        finished_at: report.fetch(:finished_at),
        metadata: { request_id: report.fetch(:request_id), provider_reported: report[:provider_reported] == true,
                    error: report[:error] }.compact
      }
    end

    def record_billable_usage(attempt)
      return attempt unless attempt.usage_known?

      attempt.with_lock do
        return attempt if attempt.token_usage_id.present?

        token_usage = TokenUsageTracker.track(
          tracked_run: chat_session,
          usage: token_usage_payload,
          cost_cents: paid_cost_cents
        )
        attempt.update!(token_usage: token_usage)
      end
    end

    def token_usage_payload
      {
        tokens_input: usage.fetch(:input_tokens),
        tokens_output: usage.fetch(:output_tokens),
        llm_model: report[:model],
        request_type: "api_attempt",
        metadata: {
          attempt_id: report.fetch(:attempt_id),
          attempt_ordinal: report.fetch(:number),
          cache_read_tokens: usage[:cache_read_tokens],
          cache_write_tokens: usage[:cache_write_tokens],
          pricing_source: pricing_source
        }.compact
      }
    end

    def usage
      @usage ||= (report[:usage] || {}).slice(:input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens)
    end

    def provider_cost
      @provider_cost ||= begin
        cost = report[:cost] || {}
        { amount: cost[:total], currency: cost[:currency]&.upcase, source: cost[:source]&.to_s,
          priced_at: cost[:priced_at] }
      end
    end

    def pricing_source
      return "provider_reported" if provider_cost[:amount].present? && provider_cost[:currency] == "USD" && provider_cost[:source] == "provider_reported"
      return "harness_estimated" if provider_cost[:amount].present? && provider_cost[:currency] == "USD" && provider_cost[:source] == "estimated"
      return "historical_estimate" if usage_known?

      "unknown"
    end

    def paid_cost_cents
      return unless %w[provider_reported harness_estimated].include?(pricing_source)

      (BigDecimal(provider_cost.fetch(:amount).to_s) * 100).round.to_i
    end

    def usage_known?
      usage[:input_tokens].present? && usage[:output_tokens].present?
    end
  end
end
