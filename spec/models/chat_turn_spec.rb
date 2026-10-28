# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-API-027
  subject(:chat_turn) { build(:chat_turn) }

  it { is_expected.to belong_to(:chat_session) }
  it { is_expected.to belong_to(:user_message).class_name("ChatMessage") }
  it { is_expected.to have_many(:events).class_name("ChatTurnEvent").dependent(:destroy) }

  it "does not consider a confirmation pause stallable" do
    chat_turn.state = "pending"

    expect(chat_turn).not_to be_stallable_at(Time.current, threshold: 15.minutes)
  end

  it "considers an inactive streaming turn stallable" do
    chat_turn.state = "streaming"
    chat_turn.last_activity_at = 16.minutes.ago

    expect(chat_turn).to be_stallable_at(Time.current, threshold: 15.minutes)
  end
end
