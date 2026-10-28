# frozen_string_literal: true

require "set"

module FeatureIntents
  # Holds the minimal synchronized issue facts a single reconciliation sweep
  # needs. It is intentionally per-job: later revisions must read fresh facts.
  # @spec DESIGN-RECONCILIATION-001
  class IssueCoverageSnapshot
    ISSUE_COLUMNS = %i[
      id project_id github_number github_state title body github_updated_at
      is_pull_request github_creator_login
    ].freeze

    PROJECT_COLUMNS = %i[
      id account_id owner repo pr_target allowed_github_usernames github_installation_id
    ].freeze

    def initialize(project:)
      @project = project
      @projects_by_name = {}
      @projects_by_id = {}
      @facts_by_project_id = {}
      @facts_by_issue_id = {}
      @manifest_associations_by_path = Hash.new { |hash, path| hash[path] = [] }
    end

    def prepare(artifacts)
      load_projects
      load_issue_facts(project.id)
      load_manifest_associations(artifacts.map { |artifact| artifact.fetch(:path) })
      self
    end

    def issue_facts_for(references, associations)
      project_names = references.map { |reference| repository_for(reference) }
      project_names.concat(associations.filter_map { |association| association[:repository] })
      authorized_projects = [ projects_by_id.fetch(project.id) ] +
        project_names.uniq.filter_map { |name| projects_by_name[name] }
      authorized_projects.uniq!(&:id)
      authorized_projects.each { |authorized_project| load_issue_facts(authorized_project.id) }
      authorized_projects.flat_map { |authorized_project| facts_by_project_id[authorized_project.id] }
    end

    def coverage_complete?(references)
      references.all? { |reference| projects_by_name.key?(repository_for(reference)) }
    end

    def local_issue_facts
      facts_by_project_id.fetch(project.id)
    end

    def issue_fact_count = facts_by_issue_id.size

    def manifest_associations_for(path)
      manifest_associations_by_path[path]
    end

    private

    attr_reader :project, :projects_by_name, :projects_by_id, :facts_by_project_id,
      :facts_by_issue_id, :manifest_associations_by_path

    def load_projects
      Project.where(account_id: project.account_id).select(*PROJECT_COLUMNS).find_each do |authorized_project|
        projects_by_name[authorized_project.full_name] = authorized_project
        projects_by_id[authorized_project.id] = authorized_project
      end
    end

    def load_issue_facts(project_id)
      return if facts_by_project_id.key?(project_id)

      facts_by_project_id[project_id] = Issue.where(project_id:).where.not(github_number: nil)
        .pluck(*ISSUE_COLUMNS).filter_map { |values| issue_fact(values) }.tap do |facts|
          facts.each { |fact| facts_by_issue_id[fact[:id]] = fact }
        end
    end

    def issue_fact(values)
      attributes = ISSUE_COLUMNS.zip(values).to_h
      authorized_project = projects_by_id[attributes[:project_id]]
      return unless authorized_project && trusted_issue?(attributes, authorized_project)

      {
        id: attributes[:id],
        repository: authorized_project.full_name,
        number: attributes[:github_number], state: attributes[:github_state],
        title: attributes[:title], body: attributes[:body],
        revision: attributes[:github_updated_at]&.iso8601
      }
    end

    def trusted_issue?(attributes, authorized_project)
      return false if attributes[:is_pull_request]

      login = attributes[:github_creator_login]
      if authorized_project.upstream_pr_target?
        authorized_project.trusted_upstream_issue_author?(login)
      else
        authorized_project.trusted_github_author?(login)
      end
    end

    def load_manifest_associations(paths)
      manifests = FeatureIntent.where(project:).pluck(:id, :design_document_paths)
      manifest_paths = manifests.to_h.transform_values { |document_paths| Array(document_paths) & paths }
      issue_ids_by_intent = FeatureIntentIssue.where(feature_intent_id: manifest_paths.keys).pluck(:feature_intent_id, :issue_id).group_by(&:first)
      load_manifest_issue_facts(issue_ids_by_intent.values.flatten(1).map(&:last))
      issue_ids_by_intent.each do |feature_intent_id, pairs|
        manifest_paths.fetch(feature_intent_id).each do |path|
          pairs.each do |(_, issue_id)|
            issue_fact_for(issue_id)&.then { |fact| manifest_associations_by_path[path] << association_for(fact, "canonical issue-tree manifest") }
          end
        end
      end
    end

    def load_manifest_issue_facts(issue_ids)
      Issue.where(id: issue_ids).pluck(:project_id).uniq.each do |issue_project_id|
        load_issue_facts(issue_project_id) if projects_by_id.key?(issue_project_id)
      end
    end

    def issue_fact_for(issue_id)
      facts_by_issue_id[issue_id]
    end

    def association_for(fact, provenance)
      { repository: fact[:repository], number: fact[:number], revision: fact[:revision], provenance: }
    end

    def repository_for(reference)
      reference.split("#", 2).first
    end
  end
end
