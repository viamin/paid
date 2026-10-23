# frozen_string_literal: true

module Inbox
  # Stable request identity and occurrence for an Inbox entry.
  #
  # The key ("<kind>:<record_id>") survives rebuilding the derived queue; the
  # occurrence is the producer-owned timestamp the request has been waiting
  # since. Polling and re-reading never change it; a fresh manual occurrence
  # does, even when the question text and state value are identical.
  #
  # @spec INBOX-PHASE-RELEVANCE-008 @spec INBOX-PHASE-RELEVANCE-007
  module RequestIdentity
    module_function

    def key_for(entry)
      entry.id
    end

    # Token compared against stored removals. Timestamps are rendered with
    # microsecond precision so two occurrences in the same second still differ.
    def occurrence_for(entry)
      entry.waiting_since&.utc&.iso8601(6) || "unknown"
    end

    def for_entry(entry)
      { key: key_for(entry), occurrence: occurrence_for(entry) }
    end
  end
end