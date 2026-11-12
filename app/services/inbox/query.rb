# frozen_string_literal: true

module Inbox
  # A Ransack-compatible boundary for the typed Inbox queue. Queue entries are
  # projections from several unrelated records, so they cannot be one
  # ActiveRecord relation. Project/repository search uses Ransack on the
  # authorized Project relation; entry-only fields are allowlisted here.
  # @spec INBOX-FOUNDATION-012
  class Query
    PREDICATES = %w[project_id_in kind_in search_cont].freeze
    PROJECT_SEARCH_PREDICATE = "owner_or_repo_cont"

    def initialize(params:, projects:, legacy_project_id: nil, legacy_kind: nil)
      @params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
      @projects = projects
      @legacy_project_id = legacy_project_id
      @legacy_kind = legacy_kind
    end

    def call(entries)
      entries.select { |entry| matches?(entry) }
    end

    def matches?(entry)
      project_match?(entry) && kind_match?(entry) && search_match?(entry)
    end

    def project_ids
      @project_ids ||= integer_values(fetch("project_id_in", legacy_project_id))
    end

    def kinds
      @kinds ||= Array(fetch("kind_in", legacy_kind)).map(&:to_s).select { Inbox::Queue::KINDS.include?(_1) }.uniq
    end

    def search
      @search ||= fetch("search_cont").to_s.strip.presence
    end

    private

    attr_reader :legacy_kind, :legacy_project_id, :params, :projects

    def fetch(predicate, fallback = nil)
      return params[predicate] if PREDICATES.include?(predicate) && params.key?(predicate)

      fallback
    end

    def integer_values(values)
      Array(values).filter_map { Integer(_1, exception: false) }.uniq
    end

    def project_match?(entry)
      project_ids.empty? || (entry_project_ids(entry) & project_ids).any?
    end

    def kind_match?(entry)
      kinds.empty? || kinds.include?(entry.kind)
    end

    def search_match?(entry)
      return true unless search

      (entry_project_ids(entry) & project_ids_for_search).any? || entry_text(entry).downcase.include?(search.downcase)
    end

    def project_ids_for_search
      @project_ids_for_search ||= projects.where(id: searchable_project_ids)
        .ransack(PROJECT_SEARCH_PREDICATE => search).result.ids
    end

    def searchable_project_ids
      @searchable_project_ids ||= projects.ids
    end

    def entry_project_ids(entry)
      return entry.record.project_ids if entry.kind == Inbox::Queue::DEPENDENCY_CYCLE_KIND

      [ entry.project&.id ].compact
    end

    def entry_text(entry)
      [ entry.title_text, entry.summary_text ].compact.join(" ")
    end
  end
end
