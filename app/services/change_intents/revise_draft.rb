# frozen_string_literal: true

module ChangeIntents
  # @spec CHANGE-INTENT-INBOX-001
  # Updates the same pending-review CIR after an operator's feedback instead
  # of creating a second Inbox entry for the same proposal.
  class ReviseDraft
    def self.call(...)
      new(...).call
    end

    def initialize(change_intent:, attributes:)
      @change_intent = change_intent
      @attributes = attributes
    end

    def call
      change_intent.revise!(attributes)
      change_intent
    end

    private

    attr_reader :attributes, :change_intent
  end
end
