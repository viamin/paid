# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::HarnessTransport, type: :service do
  # @spec API-CONVERSATION-DELEGATION-003
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:transport) { instance_double(AgentHarness::Api::ChatTransport) }
  let(:clock) { ->(_) { 100.0 } }
  let(:request) { { operation: :chat, candidates: [ { provider: :anthropic } ], messages: [] } }

  it "allocates a durable Paid request identity and passes its bound to the harness" do
    allow(transport).to receive(:call).and_return(status: :succeeded)

    described_class.new(chat_session: chat_session, transport: transport, clock: clock).call(request)

    expect(transport).to have_received(:call) do |outbound_request|
      expect(outbound_request).to include(
        request_id: "chat-#{chat_session.external_id}-1",
        retry: { max_attempts: 1 },
        timeout: { read_seconds: 60 },
        metadata: hash_including(conversation_id: chat_session.external_id, request_sequence: 1)
      )
      expect(outbound_request[:cancellation]).not_to be_cancelled
    end
  end

  it "allocates a new identity after restart rather than replaying an uncertain outbound request" do
    outbound_requests = []
    allow(transport).to receive(:call) do |outbound_request|
      outbound_requests << outbound_request
      { status: :succeeded }
    end

    described_class.new(chat_session: chat_session, transport: transport, clock: clock).call(request)
    described_class.new(chat_session: chat_session.reload, transport: transport, clock: clock).call(request)

    expect(outbound_requests.pluck(:request_id)).to eq([
      "chat-#{chat_session.external_id}-1",
      "chat-#{chat_session.external_id}-2"
    ])
  end

  it "cancels when the request deadline expires" do
    times = [ 100.0, 161.0 ]
    clock = ->(_) { times.shift || 161.0 }
    allow(transport).to receive(:call).and_return(status: :succeeded)

    described_class.new(chat_session: chat_session, transport: transport, clock: clock).call(request)

    expect(transport).to have_received(:call) do |outbound_request|
      expect(outbound_request[:cancellation]).to be_cancelled
    end
  end
end
