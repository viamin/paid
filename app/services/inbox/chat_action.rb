# frozen_string_literal: true

module Inbox
  # Keeps contextual-chat affordances exhaustive as Inbox::Queue gains lanes.
  # @spec OPERATOR-INBOX-002I
  class ChatAction
    SPECIALIZED_LABELS = {
      Queue::CLARIFYING_QUESTIONS_KIND => "Answer in chat",
      Queue::RETRY_LIMITED_KIND => "Investigate in chat",
      Queue::CHANGE_INTENT_DRAFT_KIND => "Chat about this"
    }.freeze

    def self.for(kind)
      new(kind)
    end

    def initialize(kind)
      @kind = kind.to_s
    end

    def label
      SPECIALIZED_LABELS.fetch(kind, "Chat about this")
    end

    def shared_detail?
      !SPECIALIZED_LABELS.key?(kind)
    end

    private

    attr_reader :kind
  end
end
