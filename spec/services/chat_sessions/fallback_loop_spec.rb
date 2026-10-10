# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::FallbackLoop, type: :service do
  # @spec API-CONVERSATION-DELEGATION-003
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }

  # @spec CHAT-API-006
  # @spec CHAT-API-017
  it "raises AgentHarness::RateLimitError and pauses the session for a classified 429 provider rate limit" do
    expect(Gem.loaded_specs.fetch("agent-harness").version).to be >= Gem::Version.new("0.44.9")

    configure_minimax_runner_with_429_response

    error = capture_send_message_error(chat_session)
    expect(error).to be_a(AgentHarness::RateLimitError)

    ChatSessions::MarkRateLimited.call(chat_session: chat_session, error: error)

    expect(chat_session.reload).to be_rate_limited
    expect(chat_session.messages.where(role: "system").last).to be_rate_limit_paused
  end

  it "keeps completed tool calls and results when discarding a failed runner attempt" do
    completed_call = create(:chat_message, chat_session: chat_session, role: "assistant",
      tool_name: "list_projects", tool_call_id: "call_complete")
    completed_result = create(:chat_message, chat_session: chat_session, role: "tool",
      tool_name: "list_projects", tool_call_id: "call_complete", tool_result: { "projects" => [] })
    partial_message = create(:chat_message, :assistant, chat_session: chat_session, content: "partial")

    fallback_host(chat_session).send(:discard_partial_attempt, [ completed_call.id, completed_result.id, partial_message.id ])

    expect(chat_session.messages.where(id: [ completed_call.id, completed_result.id ])).to exist
    expect(chat_session.messages.where(id: partial_message.id)).not_to exist
  end

  def fallback_host(session)
    Class.new do
      include ChatSessions::FallbackLoop

      def initialize(chat_session)
        @chat_session = chat_session
      end

      attr_reader :chat_session
    end.new(session)
  end

  # Mirrors the real MiniMax 429 ("Token Plan usage limit reached ... (2056)"):
  # a correctly classified transient/rate_limited transport result, routed
  # through the real BuildLlmClient/HttpClient classification path rather
  # than a pre-built AgentHarness::RateLimitError.
  def configure_minimax_runner_with_429_response
    api_key_record = create(:provider_api_key, user: user, api_key: "sk-minimax-test-key", api_service_type: "minimax")
    runner = create(:runner, :api_key, user: user, runner_key: "opencode",
      provider_api_key: api_key_record,
      config: { "opencode" => { "api_provider" => "minimax", "model" => "minimax-m3" } })
    chat_session.update!(runner: runner, model: "minimax-m3")

    chat_transport = instance_double(AgentHarness::Api::ChatTransport)
    allow(AgentHarness::Api::ChatTransport).to receive(:new).and_return(chat_transport)
    allow(chat_transport).to receive(:call).and_return(
      status: :failed,
      error: {
        category: :transient, code: :rate_limited, retryable: true,
        message: "Token Plan usage limit reached, please check and recharge in time (2056)"
      }
    )
  end

  def capture_send_message_error(chat_session)
    ChatSessions::SendMessage.call(chat_session: chat_session, content: "Hello")
    nil
  rescue AgentHarness::Error => e
    e
  end
end
