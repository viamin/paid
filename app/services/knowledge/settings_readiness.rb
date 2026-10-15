# frozen_string_literal: true

module Knowledge
  # Safe, local readiness details for the knowledge settings form.
  # @spec KNOWLEDGE-SETTINGS-001
  class SettingsReadiness
    Entry = Data.define(:runner, :role, :readiness)

    def self.call(...)
      new(...).call
    end

    def initialize(owner:)
      @owner = owner
    end

    def call
      {
        embedding: entries_for(:embedding),
        chat: entries_for(:chat)
      }
    end

    private

    attr_reader :owner

    def entries_for(operation)
      runners_for(operation).each_with_index.filter_map do |runner, index|
        next if runner.blank?

        Entry.new(
          runner: runner,
          role: index.zero? ? "Primary" : "Fallback #{index}",
          readiness: RunnerReadiness.call(owner:, operation:, runner:)
        )
      end
    end

    def runners_for(operation)
      setting = owner.settings
      return [ setting.kb_embedding_runner, *Array(setting.kb_embedding_fallback_runners) ] if operation == :embedding

      [ setting.kb_chat_runner, *Array(setting.kb_chat_fallback_runners) ]
    end
  end
end
