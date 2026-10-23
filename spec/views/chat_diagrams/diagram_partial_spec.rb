# frozen_string_literal: true

require "rails_helper"

RSpec.describe "chat_diagrams/_diagram", type: :view do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }
  let(:diagram) { create(:chat_diagram, chat_session:) }

  def render_diagram
    render partial: "chat_diagrams/diagram", locals: { diagram:, chat_session: }
  end

  # @spec QUESTION-EXPLORATION-003
  it "names its question and keeps the summary and text equivalent available without the visual" do
    render_diagram

    aggregate_failures do
      expect(rendered).to include(%(aria-label="Diagram for How should authentication work?"))
      expect(rendered).to include("A browser exchanges credentials for a session.")
      expect(rendered).to include("Text equivalent:")
      expect(rendered).to include("Client sends credentials to the application, which creates a session.")
      expect(rendered).to include("<details")
      expect(rendered).to include("<summary")
    end
  end

  # @spec QUESTION-EXPLORATION-003
  it "offers keyboard-reachable element selection and a comment input" do
    render_diagram

    aggregate_failures do
      expect(rendered).to include("click->diagram#select keydown->diagram#selectWithKeyboard")
      expect(rendered).to include(%(aria-pressed="false"))
      expect(rendered).to include(%(name="body"))
      expect(rendered).to include("Comment on this diagram")
    end
  end

  # @spec QUESTION-EXPLORATION-009
  it "renders Paid-owned markup only, never generated script or raw generated HTML" do
    diagram.elements.first["href"] = "https://example.com/attack"
    render_diagram

    aggregate_failures do
      expect(rendered).not_to include("<script")
      expect(rendered).not_to include("javascript:")
      expect(rendered).not_to include("onerror")
      expect(rendered).not_to include("onclick=")
    end
  end

  # @spec QUESTION-EXPLORATION-004
  it "shows a collaborator's comment with the element text it was made against" do
    create(:chat_diagram_comment, chat_diagram: diagram, actor: user, body: "What happens if this fails?",
      element_id: "app", element_context: "Application: The Paid application.")

    render_diagram

    expect(rendered).to include("What happens if this fails?")
    expect(rendered).to include("Application: The Paid application.")
  end
end
