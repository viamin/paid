# frozen_string_literal: true

module ChangeIntents
  class Activate
    attr_reader :change_intent

    def initialize(change_intent:)
      @change_intent = change_intent
    end

    def self.call(...)
      new(...).call
    end

    def call
      # @spec CHANGE-INTENT-002
      ChangeIntent.transaction do
        change_intent.activate!
        ChangeIntents::SyncKnowledgeArtifact.call(change_intent:)
      end

      {
        id: change_intent.id,
        project_id: change_intent.project_id,
        status: change_intent.reload.status,
        title: change_intent.title
      }
    end
  end
end
