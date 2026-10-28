# frozen_string_literal: true

module FeatureIntents
  # Bounded scalar coverage for one reconciliation execution. This deliberately
  # retains facts, not Active Record association graphs, and is discarded with
  # the job so revisions are never reused as evidence.
  # @spec DESIGN-RECONCILIATION-001
  class IssueCoverageSnapshot
    PROJECT_FIELDS = %i[id account_id owner repo allowed_github_usernames pr_target upstream_full_name github_installation_id].freeze
    ISSUE_FIELDS = %i[id project_id github_number github_state title body github_updated_at is_pull_request github_creator_login].freeze

    def initialize(project:)
      @project = project
      @projects_by_id = projects.index_by(&:id)
      @projects_by_repository = @projects_by_id.values.index_by(&:full_name)
      @issues_by_id = {}
      @issues_by_project_and_number = {}
      @coverage_by_project_id = Hash.new { |hash, key| hash[key] = [] }
      load_issues
      load_manifest_associations
    end

    def issue_for(number)
      @issues_by_project_and_number[[ project.id, number ]]
    end

    def issue_count = @issues_by_id.size

    def coverage(references:, associations:)
      projects = [ project.id ] + referenced_projects(references) + association_project_ids(associations)
      facts = projects.uniq.flat_map { |project_id| @coverage_by_project_id[project_id] }
      [ facts, references.all? { |reference| projects_by_repository.key?(repository_for(reference)) } ]
    end

    def trusted_issues_for_project = @coverage_by_project_id[project.id]

    def manifest_associations_for(path) = @manifest_associations_by_path.fetch(path, [])

    def feature_intent_associations_for(feature_intent_id)
      @feature_intent_associations.fetch(feature_intent_id, [])
    end

    private

    attr_reader :project, :projects_by_id, :projects_by_repository

    def projects
      Project.where(account_id: project.account_id).select(*PROJECT_FIELDS).to_a
    end

    def load_issues
      Issue.where(project_id: projects_by_id.keys).where.not(github_number: nil).select(*ISSUE_FIELDS).find_each do |issue|
        fact = fact_for(issue)
        @issues_by_id[issue.id] = fact
        @issues_by_project_and_number[[ issue.project_id, issue.github_number ]] = fact
        @coverage_by_project_id[issue.project_id] << fact if !fact[:pull_request] && fact[:trusted]
      end
    end

    def fact_for(issue)
      {
        id: issue.id, project_id: issue.project_id, repository: projects_by_id.fetch(issue.project_id).full_name,
        number: issue.github_number, state: issue.github_state, title: issue.title, body: issue.body,
        revision: issue.github_updated_at&.iso8601, pull_request: issue.is_pull_request,
        trusted: trusted?(issue)
      }
    end

    def trusted?(issue)
      issue.project = projects_by_id.fetch(issue.project_id)
      issue.trusted?
    end

    def load_manifest_associations
      paths_by_feature_intent = FeatureIntent.where(project:).pluck(:id, :design_document_paths).to_h
      @feature_intent_associations = Hash.new { |hash, key| hash[key] = [] }
      @manifest_associations_by_path = Hash.new { |hash, key| hash[key] = [] }
      FeatureIntentIssue.where(feature_intent_id: paths_by_feature_intent.keys).pluck(:feature_intent_id, :issue_id).each do |feature_intent_id, issue_id|
        issue = @issues_by_id[issue_id]
        next unless issue

        association = association_for(issue, "canonical issue-tree manifest")
        @feature_intent_associations[feature_intent_id] << association
        Array(paths_by_feature_intent.fetch(feature_intent_id)).each do |path|
          @manifest_associations_by_path[path] << association
        end
      end
    end

    def association_for(issue, provenance)
      {
        repository: issue.fetch(:repository), number: issue.fetch(:number), revision: issue[:revision], provenance:,
        project_id: issue.fetch(:project_id)
      }.compact
    end

    def referenced_projects(references)
      references.filter_map { |reference| projects_by_repository[repository_for(reference)]&.id }
    end

    def association_project_ids(associations) = associations.filter_map { |association| association[:project_id] }

    def repository_for(reference) = reference.split("#", 2).first
  end
end
