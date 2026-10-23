# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatDiagrams::Serializer do
  # @spec QUESTION-EXPLORATION-004 QUESTION-EXPLORATION-012
  it "serializes only the most recent comments in chronological order" do
    diagram = create(:chat_diagram)
    comments = 21.times.map do |index|
      create(:chat_diagram_comment, chat_diagram: diagram, body: "Comment #{index + 1}",
        created_at: (21 - index).seconds.ago)
    end

    serialized_comments = described_class.call(diagram.reload).fetch(:comments)

    expect(serialized_comments.pluck(:id)).to eq(comments.last(described_class::COMMENT_LIMIT).pluck(:id))
  end
end
