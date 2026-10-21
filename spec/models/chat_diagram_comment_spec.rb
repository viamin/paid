# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatDiagramComment do
  # @spec QUESTION-EXPLORATION-004
  it "rejects a comment body longer than a chat message" do
    comment = build(:chat_diagram_comment, body: "a" * 12_001)

    expect(comment).not_to be_valid
    expect(comment.errors.of_kind?(:body, :too_long)).to be(true)
  end
end
