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

    # @spec MOBILE-API-008
    def call
      return unless Inbox::Queue::KINDS.include?(kind)

      Inbox::Queue.call(user:, kind:).find { |entry| entry.id == entry_id }
    end

    private

    attr_reader :entry_id, :user

    def kind
      @kind ||= entry_id.split(":", 2).first
    end
  end
end
