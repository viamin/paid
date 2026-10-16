# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatDiagram do
  subject(:diagram) { build(:chat_diagram) }

  it { is_expected.to belong_to(:chat_session) }
  it { is_expected.to belong_to(:chat_message).optional }
  it { is_expected.to have_many(:comments).class_name("ChatDiagramComment").dependent(:restrict_with_exception) }

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
end
