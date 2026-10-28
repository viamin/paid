# frozen_string_literal: true

require "rails_helper"

RSpec.describe "chat_messages/_stalled_turn_notice" do
  # @spec CHAT-API-027
  it "links the durable notice to the unfinished request" do
    message = build(:chat_message, :system, id: 2, metadata: { "user_message_id" => 1 })

    render partial: "chat_messages/stalled_turn_notice", locals: { message: }

    expect(rendered).to include("Request needs attention", "#chat-message-1")
  end
end
