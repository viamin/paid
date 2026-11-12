# frozen_string_literal: true

module Inbox
  # Ransack-compatible boundary for the heterogeneous Inbox::Queue projection.
  # Queue entries originate in several unrelated models, so they cannot form a
  # single Active Record relation. This adapter deliberately accepts only the
  # three predicates exposed by the Inbox UI and applies them after Queue has
  # established authorization, phase relevance, and personal removals.
  # @spec OPERATOR-INBOX-027 OPERATOR-INBOX-028
  class Search
    ALLOWED_PREDICATES = %w[kind_in project_id_in search_cont].freeze

    def initialize(params: {})
      @params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
    end

    def call(entries)
      entries.select { |entry| matches?(entry) }
    end

    def kinds
      values_for("kind_in").intersection(Queue::KINDS)
    end

    def project_ids
      values_for("project_id_in").filter_map { |value| Integer(value, exception: false) }.uniq
    end

    def search
      @search ||= value_for("search_cont").to_s.strip.presence
    end

    def filter_active?
      kinds.any? || project_ids.any?
    end

    private

    attr_reader :params

    def matches?(entry)
      (kinds.empty? || kinds.include?(entry.kind)) &&
        (project_ids.empty? || project_ids.include?(entry.project&.id)) &&
        matches_search?(entry)
    end

    def matches_search?(entry)
      return true if search.blank?

      searchable_text(entry).downcase.include?(search.downcase)
    end

    def searchable_text(entry)
      [ entry.project&.full_name, entry.title, entry.summary ].compact.join(" ")
    end

    def values_for(predicate)
      return [] unless ALLOWED_PREDICATES.include?(predicate)

      Array(query_params[predicate]).filter_map { |value| value.to_s.presence }.uniq
    end

    def value_for(predicate)
      values_for(predicate).first
    end

    def query_params
      @query_params ||= params.fetch("q", params.fetch(:q, {})).to_h.stringify_keys.slice(*ALLOWED_PREDICATES)
    end
  end
end
