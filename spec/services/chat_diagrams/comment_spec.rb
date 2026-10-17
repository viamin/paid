# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatDiagrams::Comment do
  let(:diagram) { create(:chat_diagram) }
  let(:actor) { diagram.chat_session.created_by }

  # @spec QUESTION-EXPLORATION-004 QUESTION-EXPLORATION-006
  it "copies the selected element's text at comment time" do
    comment = described_class.call(diagram:, actor:, body: "What happens if this fails?", element_id: "app")

    expect(comment).to have_attributes(
      actor:,
      question_key: diagram.question_key,
      element_id: "app",
      element_context: "Application: The Paid application."
    )
  end

  # @spec QUESTION-EXPLORATION-006
  it "rejects an element that no longer belongs to the selected diagram" do
    expect {
      described_class.call(diagram:, actor:, body: "Please explain", element_id: "removed")
    }.to raise_error(described_class::StaleElementError, /no longer available/)
  end
end
