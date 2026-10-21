# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatDiagrams::Replace do
  let(:diagram) { create(:chat_diagram) }

  # @spec QUESTION-EXPLORATION-005
  it "discards superseded visual source while preserving its human comments" do
    comment = create(:chat_diagram_comment, chat_diagram: diagram, actor: diagram.chat_session.created_by,
      question_key: diagram.question_key, element_id: "app", element_context: "Application: The Paid application.")

    replacement = described_class.call(chat_session: diagram.chat_session, question_key: diagram.question_key,
      question_title: diagram.question_title, summary: "A refreshed view.", text_equivalent: "A refreshed textual view.",
      description: build(:chat_diagram).description)

    expect(replacement).to be_current
    expect(diagram.reload).not_to be_current
    expect(diagram.description).to eq({})
    expect(comment.reload.element_context).to eq("Application: The Paid application.")
  end

  # @spec QUESTION-EXPLORATION-005
  it "keeps current diagrams for other questions reconnectable" do
    other_diagram = create(:chat_diagram, chat_session: diagram.chat_session, question_key: "data-storage")

    described_class.call(chat_session: diagram.chat_session, question_key: diagram.question_key,
      question_title: diagram.question_title, summary: "A refreshed view.", text_equivalent: "A refreshed textual view.",
      description: build(:chat_diagram).description)

    expect(other_diagram.reload).to be_current
    expect(other_diagram.description).to be_present
  end
end
