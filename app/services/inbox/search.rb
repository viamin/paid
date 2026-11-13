# frozen_string_literal: true

module Inbox
  # Ransack boundary for the heterogeneous Inbox entry projection. Queue entries
  # are intentionally not persisted in one table: every lane retains its own
  # authorization and renderability query. This adapter limits public search to
  # one documented predicate, then asks Ransack to search the persisted Project
  # and Issue records that back the authorized entries. Synthetic entry text is
  # matched only after queue authorization because it has no common relation.
  class Search
    TEXT_PREDICATE = "text_cont"

    def self.call(...)
      new(...).call
    end

    def initialize(entries:, query: nil)
      @entries = entries
      @query = query
    end

    # @spec INBOX-FOUNDATION-012
    def call
      return entries if term.blank?

      entries.select do |entry|
        displayed_text_matches?(entry) ||
          project_ids.intersect?(entry_project_ids(entry)) || issue_ids.intersect?(entry_issue_ids(entry))
      end
    end

    private

    attr_reader :entries, :query

    def term
      @term ||= query.to_h.stringify_keys.slice(TEXT_PREDICATE).fetch(TEXT_PREDICATE, "").to_s.strip.presence
    end

    def project_ids
      @project_ids ||= Project.where(id: entries.flat_map { |entry| entry_project_ids(entry) }.uniq)
        .ransack({ "owner_or_repo_cont" => term }, auth_object: :inbox).result(distinct: true).pluck(:id).to_set
    end

    def issue_ids
      @issue_ids ||= Issue.where(id: entries.flat_map { |entry| entry_issue_ids(entry) }.uniq)
        .ransack({ "title_or_body_cont" => term }, auth_object: :inbox).result(distinct: true).pluck(:id).to_set
    end

    def entry_project_ids(entry)
      ([ entry.project&.id ] + entry_issues(entry).map(&:project_id)).compact.uniq
    end

    def entry_issue_ids(entry)
      entry_issues(entry).map(&:id)
    end

    def entry_issues(entry)
      return entry.record.issues if entry.record.is_a?(Issues::DependencyCycles::Cycle)

      [ entry.issue ].compact
    end

    def displayed_text_matches?(entry)
      [ entry.title_text, entry.summary_text ].compact.any? { |text| text.to_s.downcase.include?(normalized_term) }
    end

    def normalized_term
      @normalized_term ||= term.downcase
    end
  end
end
