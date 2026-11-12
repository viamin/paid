# frozen_string_literal: true

module Inbox
  # Applies the public Inbox search contract after Queue has assembled its
  # heterogeneous, policy-scoped entries. Queue entries are derived from many
  # record types, so they cannot be represented by one Active Record relation.
  # Ransack narrows the two relational fields (project owner/repository and
  # issue title); this adapter applies the same explicitly allowlisted text
  # predicate to derived entry title/summary values.
  # @spec INBOX-FOUNDATION-012
  class Query
    TEXT_PREDICATE = "text_cont"
    PROJECT_PREDICATE = "owner_or_repo_cont"

    def self.call(...) = new(...).call

    def initialize(entries:, search: nil, projects: [], kinds: [])
      @entries = entries
      @search = search.to_h.slice(TEXT_PREDICATE).transform_values(&:to_s)
      @projects = projects
      @kinds = kinds
    end

    def call
      entries.select { |entry| kinds.empty? || kinds.include?(entry.kind) }
        .then { |results| filter_projects(results) }
        .then { |results| filter_text(results) }
    end

    private

    attr_reader :entries, :kinds, :projects, :search

    def filter_projects(entries)
      return entries if projects.empty?

      entries.select { |entry| projects_for(entry).any? { |project| projects.include?(project) } }
    end

    def filter_text(results)
      query = search[TEXT_PREDICATE].to_s.strip
      return results if query.blank?

      project_ids = searchable_projects(query)
      issue_ids = searchable_issues(results, query)
      results.select do |entry|
        projects_for(entry).any? { |project| project_ids.include?(project.id) } ||
          issue_ids.include?(entry.issue&.id) || derived_text(entry).include?(query.downcase)
      end
    end

    def searchable_projects(query)
      Project.where(id: projects_for_all(entries).map(&:id)).ransack(PROJECT_PREDICATE => query).result.ids
    end

    def searchable_issues(results, query)
      Issue.where(id: results.filter_map { |entry| entry.issue&.id }).ransack("title_cont" => query).result.ids
    end

    def projects_for_all(entries)
      entries.flat_map { |entry| projects_for(entry) }.compact.uniq
    end

    def projects_for(entry)
      return entry.record.issues.map(&:project) if entry.dependency_cycle?

      [ entry.project ]
    end

    def derived_text(entry)
      [ entry.title, entry.summary ].compact.join(" ").downcase
    end
  end
end
