# frozen_string_literal: true

module Inbox
  # A Ransack-compatible boundary for the typed, in-memory Inbox queue.
  #
  # Inbox entries are composed from Issues, notifications, feature intents,
  # and graph components. They do not share an ActiveRecord relation, so a
  # conventional `.ransack` call would either lose lane predicates or expose
  # fields from an unrelated backing model. This adapter keeps the Ransack
  # predicate vocabulary at that boundary and applies it after Queue has
  # enforced each lane's authorization, relevance, and removal rules.
  # @spec OPERATOR-INBOX-027
  class EntrySearch
    PREDICATES = {
      "kind_in" => :array,
      "project_id_in" => :integer_array,
      "search_cont" => :string
    }.freeze

    def self.call(entries:, query:)
      new(query:).call(entries)
    end

    def self.permitted_params(params)
      query = params[:q]
      return ActionController::Parameters.new.permit! unless query.respond_to?(:permit)

      query.permit(:search_cont, kind_in: [], project_id_in: [])
    end

    def initialize(query:)
      @query = query.respond_to?(:to_unsafe_h) ? query.to_unsafe_h : query.to_h
    end

    def call(entries)
      entries.select { |entry| matches?(entry) }
    end

    def kind_values
      values_for("kind_in").intersection(Queue::KINDS)
    end

    def project_ids
      values_for("project_id_in").filter_map { |value| Integer(value, exception: false) }.uniq
    end

    def search_term
      value_for("search_cont").to_s.strip.presence
    end

    def active?
      kind_values.any? || project_ids.any? || search_term.present?
    end

    def text_only_query
      { "search_cont" => search_term }.compact
    end

    private

    attr_reader :query

    def matches?(entry)
      matches_kinds?(entry) && matches_projects?(entry) && matches_search?(entry)
    end

    def matches_kinds?(entry)
      kind_values.empty? || kind_values.include?(entry.kind)
    end

    def matches_projects?(entry)
      project_ids.empty? || entry_project_ids(entry).intersect?(project_ids)
    end

    def matches_search?(entry)
      return true unless search_term

      searchable_text(entry).downcase.include?(search_term.downcase)
    end

    def entry_project_ids(entry)
      return entry.record.project_ids if entry.dependency_cycle?

      [ entry.project&.id ].compact
    end

    def searchable_text(entry)
      [ entry.project&.full_name, entry.title, entry.summary, entry.issue&.title ].compact.join(" ")
    end

    # Ignore unknown predicates rather than expanding the query surface. The
    # names are Ransack predicate keys; asking Ransack to resolve them keeps
    # this adapter aligned with the installed predicate contract.
    def values_for(predicate)
      return [] unless predicate_allowed?(predicate)

      Array(query[predicate]).map(&:to_s).reject(&:blank?)
    end

    def value_for(predicate)
      return unless predicate_allowed?(predicate)

      query[predicate]
    end

    def predicate_allowed?(predicate)
      PREDICATES.key?(predicate) && Ransack::Predicate.named(predicate.split("_").last).present?
    end
  end
end
