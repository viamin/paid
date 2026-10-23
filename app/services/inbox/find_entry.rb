# frozen_string_literal: true

module Inbox
  class FindEntry
    def self.call(...)
      new(...).call
    end

    def initialize(user:, entry_id:)
      @user = user
      @entry_id = entry_id.to_s
    end

    # @spec MOBILE-API-008 @spec INBOX-PHASE-RELEVANCE-003
    # Searches every scope: an authorized user may inspect a request that
    # phase relevance or their own removal moved out of the default list.
    def call
      return unless Inbox::Queue::KINDS.include?(kind)

      Inbox::Queue::SCOPES.each do |scope|
        entry = Inbox::Queue.call(user:, kind:, scope:).find { |candidate| candidate.id == entry_id }
        return entry if entry
      end

      nil
    end

    private

    attr_reader :entry_id, :user

    def kind
      @kind ||= entry_id.split(":", 2).first
    end
  end
end
