# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::RecoverStalledTurn do
  # @spec CHAT-TURN-RECOVERY-005
  it "records one explicit safe recovery without replaying the turn" do
    account = create(:account)
    actor = create(:user, account: account)
    session = create(:chat_session, account: account, created_by: actor)
    user_message = create(:chat_message, chat_session: session, role: "user")
    turn = create(:chat_turn, chat_session: session, user_message: user_message, status: "stalled")

    described_class.call(turn: turn, actor: actor)
    described_class.call(turn: turn, actor: actor)

    expect(turn.reload).to have_attributes(status: "abandoned", recovery_attempts: 1)
    notices = session.messages.where("metadata ->> 'stalled_turn_recovery' = 'true'")
    expect(notices.count).to eq(1)
  end
end
