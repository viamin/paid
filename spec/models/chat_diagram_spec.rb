# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatDiagram do
  subject(:diagram) { build(:chat_diagram) }

  it { is_expected.to belong_to(:chat_session) }
  it { is_expected.to belong_to(:chat_message).optional }
  it { is_expected.to have_many(:comments).class_name("ChatDiagramComment").dependent(:destroy) }

  # @spec QUESTION-EXPLORATION-003 QUESTION-EXPLORATION-009
  it "accepts a constrained, relationship-aware description" do
    expect(diagram).to be_valid
  end

  # @spec QUESTION-EXPLORATION-009
  it "rejects executable links and relationships to unknown elements" do
    diagram.description["elements"].first["href"] = "javascript:alert(1)"
    diagram.description["relationships"] = [ { "from" => "client", "to" => "missing" } ]

    expect(diagram).not_to be_valid
    expect(diagram.errors[:description]).to include("contains an unsafe link", "references an unknown element")
  end

  # @spec QUESTION-EXPLORATION-009
  it "rejects non-string links without raising" do
    diagram.description["elements"].first["href"] = 5

    expect { diagram.valid? }.not_to raise_error
    expect(diagram.errors[:description]).to include("contains an unsafe link")
  end

  # @spec QUESTION-EXPLORATION-005 QUESTION-EXPLORATION-012
  it "broadcasts its question key so clients can replace a superseded diagram" do
    diagram.chat_session.save!

    expect(ActionCable.server).to receive(:broadcast).with(
      "chat_session:#{diagram.chat_session.id}", hash_including(type: "diagram_created", question_key: diagram.question_key)
    )

    diagram.save!
  end
end
