# frozen_string_literal: true

module Inbox
  module Removals
    # Remove and restore a personal Inbox request. Removal hides the request for
    # one user only and never resolves it, cancels work, changes automation
    # authorization, or deletes questions and history.
    #
    # @spec INBOX-PHASE-RELEVANCE-006
    class Remove
      def self.call(...)
        new(...).call
      end

      def initialize(entry:, user:)
        @entry = entry
        @user = user
      end

      def call
        InboxRemoval.find_or_initialize_by(
          user: user,
          request_key: Inbox::RequestIdentity.key_for(entry),
          request_occurrence: Inbox::RequestIdentity.occurrence_for(entry)
        ).tap do |removal|
          removal.assign_attributes(
            project: entry.project,
            entry_kind: entry.kind,
            responsible_phase: Inbox::PhaseOwnership.for_entry(entry).responsible_phase,
            removed_at: Time.current,
            cleared_at: nil
          )
          removal.save!
        end
      end

      private

      attr_reader :entry, :user
    end

    # Clears a user's suppression so the request becomes eligible again.
    # @spec INBOX-PHASE-RELEVANCE-006
    class Restore
      def self.call(...)
        new(...).call
      end

      def initialize(entry:, user:)
        @entry = entry
        @user = user
      end

      def call
        removed = InboxRemoval.active.where(user:, request_key: Inbox::RequestIdentity.key_for(entry))
        removed.find_each(&:clear!)
      end

      private

      attr_reader :entry, :user
    end

    # Answers, in one batched query, which of the given entries are personally
    # removed for this user at their current occurrence.
    #
    # @spec INBOX-PHASE-RELEVANCE-009
    class Suppression
      def self.call(...)
        new(...).call
      end

      def initialize(user:, entries:)
        @user = user
        @entries = entries
      end

      def call
        @call ||= begin
          keys = entries.map { |entry| Inbox::RequestIdentity.key_for(entry) }.uniq
          return Set.new if keys.empty?

          removals = InboxRemoval.active.where(user:, request_key: keys).to_a
          suppressed = Set.new
          entries_by_key = entries.index_by { |entry| Inbox::RequestIdentity.key_for(entry) }
          removals.each do |removal|
            entry = entries_by_key[removal.request_key]
            next unless entry

            suppressed << entry.id if removal.suppresses?(Inbox::RequestIdentity.occurrence_for(entry))
          end
          suppressed
        end
      end

      private

      attr_reader :entries, :user
    end
  end
end
