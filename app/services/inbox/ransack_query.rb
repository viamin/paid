# frozen_string_literal: true

module Inbox
  # Ransack-compatible filtering for the heterogeneous, in-memory Inbox entry
  # projection. See OPERATOR-INBOX-028 for why this cannot be an AR relation.
  class RansackQuery
    ALLOWED_PREDICATES = %w[kind_in project_id_in search_cont].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(entries:, params:)
      @entries = entries
      @params = params.to_h.slice(*ALLOWED_PREDICATES)
    end

    # @spec OPERATOR-INBOX-028
    def call
      entries.select { |entry| matches?(entry) }
    end

    private

    attr_reader :entries, :params

    def matches?(entry)
      matches_kinds?(entry) && matches_projects?(entry) && matches_search?(entry)
    end

    def matches_kinds?(entry)
      kinds = values_for("kind_in").select { |kind| Inbox::Queue::KINDS.include?(kind) }
      kinds.empty? || kinds.include?(entry.kind)
    end

    def matches_projects?(entry)
      project_ids = values_for("project_id_in").filter_map { |id| Integer(id, exception: false) }
      project_ids.empty? || entry_project_ids(entry).intersect?(project_ids)
    end

    def matches_search?(entry)
      query = params["search_cont"].to_s.strip.downcase
      query.blank? || searchable_text(entry).include?(query)
    end

    def entry_project_ids(entry)
      return entry.record.project_ids if entry.respond_to?(:dependency_cycle?) && entry.dependency_cycle?

      [ entry.project&.id ].compact
    end

    def searchable_text(entry)
      [ entry.project&.full_name, entry.title, entry.summary ].compact.join(" ").downcase
    end

    def values_for(predicate)
      Array(params[predicate]).filter_map { |value| value.to_s.presence }
    end
  end
end
