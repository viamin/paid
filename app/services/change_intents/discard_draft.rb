# frozen_string_literal: true

module ChangeIntents
  class DiscardDraft
    attr_reader :change_intent

    def initialize(change_intent:)
      @change_intent = change_intent
    end

    def self.call(...)
      new(...).call
    end

    def call
      change_intent.with_lock do
        change_intent.reload
        unless change_intent.status == "draft"
          raise ChangeIntent::InvalidTransitionError, "cannot discard from #{change_intent.status}"
        end

        result = {
          id: change_intent.id,
          project_id: change_intent.project_id,
          status: "denied",
          title: change_intent.title,
          disposition: "deleted_draft"
        }
        change_intent.destroy!
        result
      end
    end
  end
end
