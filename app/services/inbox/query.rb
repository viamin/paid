# frozen_string_literal: true

module Inbox
  # Ransack-compatible boundary for the heterogeneous Inbox projection. Inbox
  # entries are value objects assembled from several policy-scoped relations,
  # so they cannot be exposed as one Active Record relation. Project/repository
  # search is executed by Ransack; title and summary search is the equivalent
  # allowlisted predicate over the resulting presentation values.
  #
  # Only the predicates below are accepted. In particular, this class never
  # forwards arbitrary `q` keys to Ransack.
  # @spec INBOX-FOUNDATION-012
  class Query
    SEARCH_PREDICATES = %w[project_owner_or_repo_cont title_or_summary_cont].freeze

    def self.from_params(params)
      query = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params
      new(
        project_ids: query["project_ids"] || query[:project_ids] || query["project_id"] || query[:project_id],
        kinds: query["kinds"] || query[:kinds] || query["kind"] || query[:kind],
        search: query["q"] || query[:q]
      )
    end

    def initialize(project_ids: nil, kinds: nil, search: nil)
      @project_ids = Array(project_ids).filter_map { |id| Integer(id, exception: false) }.uniq
      @kinds = Array(kinds).map(&:to_s).intersection(Queue::KINDS)
      @search = search.to_h.stringify_keys.slice(*SEARCH_PREDICATES).transform_values { |value| value.to_s.strip.presence }
    end

    attr_reader :kinds, :project_ids, :search

    def call(entries)
      filter_by_kind(filter_by_project(search_entries(entries)))
    end

    def search_entries(entries)
      filter_by_entry_text(filter_by_project_search(entries))
    end

    def active?
      project_ids.any? || kinds.any? || search.values.any?
    end

    private

    def filter_by_kind(entries)
      kinds.any? ? entries.select { |entry| kinds.include?(entry.kind) } : entries
    end

    def filter_by_project(entries)
      project_ids.any? ? entries.select { |entry| entry_project_ids(entry).intersect?(project_ids) } : entries
    end

    def filter_by_project_search(entries)
      term = search["project_owner_or_repo_cont"]
      return entries unless term

      ids = Project.where(id: entries.flat_map { |entry| entry_project_ids(entry) }.uniq)
        .ransack({ "owner_or_repo_cont" => term }, auth_object: :inbox)
        .result
        .ids
      entries.select { |entry| entry_project_ids(entry).intersect?(ids) }
    end

    def filter_by_entry_text(entries)
      term = search["title_or_summary_cont"]
      return entries unless term

      entries.select { |entry| [ entry.title, entry.summary ].compact.join(" ").downcase.include?(term.downcase) }
    end

    def entry_project_ids(entry)
      return entry.record.project_ids if entry.dependency_cycle?

      [ entry.project&.id ].compact
    end
  end
end
