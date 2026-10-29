# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::SendMessage, ".call" do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:llm_response) do
    { content: "Done.", tool_calls: [], tokens_input: 10, tokens_output: 5, model: "gpt-4o" }
  end

  after do
    ChatTurnLifecycleEvent.where(chat_session: chat_session).delete_all
    account.destroy!
  end

  # @spec CHAT-TURN-RECOVERY-001 @spec CHAT-TURN-RECOVERY-002
  it "keeps a callback-free JSON-style provider call out of stall classification" do
    stub_const("ChatTurn::HEARTBEAT_INTERVAL", 0.01.seconds)
    provider_started = Queue.new
    provider_release = Queue.new
    quiet_client = blocking_client(provider_started, provider_release)
    sender = send_in_background(quiet_client)
    provider_started.pop

    turn = wait_for_turn
    initial_heartbeat = turn.attempt_heartbeat_at
    wait_for_heartbeat_after(turn, initial_heartbeat)
    turn.update!(last_activity_at: 10.minutes.ago)

    ChatTurns::StallDetectorJob.perform_now

    expect(turn.reload.status).to eq("streaming")
  ensure
    provider_release << true if sender&.alive?
    if sender
      raise "Callback-free send timed out" unless sender.join(10)

      sender.value
    end
  end

  private

  def blocking_client(provider_started, provider_release)
    lambda do |_conversation|
      provider_started << true
      provider_release.pop
      llm_response
    end
  end

  def send_in_background(client)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.call(chat_session: ChatSession.find(chat_session.id), content: "Hello", llm_client: client)
      end
    end
  end

  def wait_for_turn
    Timeout.timeout(1) do
      loop do
        turn = ChatTurn.find_by(chat_session: chat_session)
        break turn if turn

        Thread.pass
      end
    end
  end

  def wait_for_heartbeat_after(turn, timestamp)
    Timeout.timeout(1) do
      loop do
        break if turn.reload.attempt_heartbeat_at > timestamp

        Thread.pass
      end
    end
  end
end
