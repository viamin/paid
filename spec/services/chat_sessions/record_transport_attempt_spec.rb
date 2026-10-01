# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::RecordTransportAttempt do
  let(:chat_session) { create(:chat_session, :with_project) }
  let(:actor) { chat_session.created_by }
  let(:message) { create(:chat_message, chat_session: chat_session, role: "user") }

  # @spec API-CONVERSATION-DELEGATION-002
  it "persists a failed reported attempt once and bills its provider-reported USD cost" do
    report = attempt_report(status: :failed)

    expect {
      2.times { described_class.call(chat_session:, actor:, message:, report:) }
    }.to change(ApiUsageAttempt, :count).by(1)
      .and change(TokenUsage, :count).by(1)

    expect_persisted_failed_attempt
  end

  # @spec API-CONVERSATION-DELEGATION-002
  it "does not bill a redelivery that changes the ordinal for the same physical attempt" do
    described_class.call(chat_session:, actor:, message:, report: attempt_report)

    expect {
      described_class.call(chat_session:, actor:, message:, report: attempt_report(number: 2))
    }.not_to change(TokenUsage, :count)
  end

  # @spec API-CONVERSATION-DELEGATION-002
  it "retains missing usage as unknown without creating a zero-valued billing record" do
    attempt = described_class.call(
      chat_session:,
      actor:,
      message:,
      report: attempt_report(usage: nil, cost: nil)
    )

    aggregate_failures do
      expect(attempt).to be_usage_unknown
      expect(attempt.token_usage).to be_nil
      expect(TokenUsage.where(request_type: "api_attempt")).to be_empty
    end
  end

  # @spec API-CONVERSATION-DELEGATION-002
  it "retains non-USD provider charges while billing with the historical Paid estimate" do
    create(:llm_model, model_id: "gpt-test", input_cost_per_million: 2, output_cost_per_million: 10)

    attempt = described_class.call(
      chat_session:,
      actor:,
      message:,
      report: attempt_report(
        usage: { input_tokens: 1_000_000, output_tokens: 1_000_000 },
        cost: { total: "0.02", currency: "EUR", source: :provider_reported, priced_at: Time.current }
      )
    )

    aggregate_failures do
      expect(attempt).to have_attributes(
        provider_cost_amount: BigDecimal("0.02"),
        provider_currency: "EUR",
        pricing_source: "historical_estimate"
      )
      expect(attempt.token_usage.cost_cents).to eq(1200)
    end
  end

  # @spec API-CONVERSATION-DELEGATION-002
  it "retains harness-estimated USD cost provenance and uses its historical amount" do
    attempt = described_class.call(
      chat_session:,
      actor:,
      message:,
      report: attempt_report(cost: { total: "0.02", currency: "USD", source: :estimated, priced_at: Time.current })
    )

    expect(attempt).to have_attributes(pricing_source: "harness_estimated")
    expect(attempt.token_usage.cost_cents).to eq(2)
  end

  def attempt_report(number: 1, status: :succeeded, usage: { input_tokens: 120, output_tokens: 30, cache_read_tokens: 15, cache_write_tokens: 5 },
    cost: { total: "0.01234", currency: "USD", source: :provider_reported, priced_at: Time.current })
    {
      attempt_id: "attempt-123",
      request_id: "request-456",
      number: number,
      provider: :openai,
      model: "gpt-test",
      status: status,
      started_at: 1.minute.ago,
      finished_at: Time.current,
      usage: usage,
      cost: cost,
      provider_reported: true
    }
  end

  def expect_persisted_failed_attempt
    attempt = ApiUsageAttempt.last
    usage = TokenUsage.last

    aggregate_failures do
      expect(attempt).to have_attributes(
        account: chat_session.account, project: chat_session.project,
        chat_session: chat_session, chat_message: message, actor: actor,
        attempt_id: "attempt-123", ordinal: 1, status: "failed",
        input_tokens: 120, output_tokens: 30, cache_read_tokens: 15,
        cache_write_tokens: 5, provider_cost_amount: BigDecimal("0.01234"),
        provider_currency: "USD", pricing_source: "provider_reported"
      )
      expect(attempt.token_usage).to eq(usage)
      expect(usage).to have_attributes(chat_session: chat_session, input_tokens: 120,
        output_tokens: 30, cost_cents: 1, request_type: "api_attempt")
      expect(usage.metadata).to include("attempt_id" => "attempt-123", "attempt_ordinal" => 1,
        "cache_read_tokens" => 15, "cache_write_tokens" => 5, "pricing_source" => "provider_reported")
    end
  end
end
