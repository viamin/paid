# frozen_string_literal: true

module ChatDiagrams
  # Persists context rather than a live element pointer, so a later redraw
  # cannot cause a comment to be silently retargeted.
  # @spec QUESTION-EXPLORATION-004 QUESTION-EXPLORATION-006
  class Comment
    class StaleElementError < ArgumentError; end

    def self.call(...) = new(...).call

    def initialize(diagram:, actor:, body:, element_id: nil)
      @diagram = diagram
      @actor = actor
      @body = body
      @element_id = element_id.presence
    end

    def call
      ChatDiagramComment.create!(attributes)
    end

    private

    attr_reader :diagram, :actor, :body, :element_id

    def attributes
      { chat_diagram: diagram, actor:, body:, question_key: diagram.question_key }.merge(selected_element_attributes)
    end

    def selected_element_attributes
      return {} unless element_id

      element = diagram.element(element_id) || raise(StaleElementError, "That diagram element is no longer available; please clarify your comment.")
      { element_id:, element_context: "#{element.fetch("label")}: #{element.fetch("description")}" }
    end
  end
end
