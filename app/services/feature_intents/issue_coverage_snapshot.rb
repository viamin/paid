# frozen_string_literal: true

module FeatureIntents
  # Per-execution, scalar issue evidence used while reconciling design artifacts.
  # @spec DESIGN-RECONCILIATION-001
  class IssueCoverageSnapshot
    ISSUE_COLUMNS = %i[project_id github_number github_state title body github_updated_at is_pull_request github_creator_login].freeze

    def initialize(project:)
      @project = project
      @projects_by_id = { project.id => project }
      @projects_by_repository = { project.full_name => project }
      @facts_by_project_id = {}
    end

    def coverage_for(references:, associated_issues: [], artifact_path:)
      projects = { project.full_name => project }.merge(projects_for(references))
      associations = associated_issues + backlink_associations(artifact_path) + manifest_associations(artifact_path)
      associated_projects = projects_for_ids(associations.filter_map { |association| association[:project_id] })
      facts = facts_for((projects.values + associated_projects).uniq).reject do |fact|
        fact[:is_pull_request] || !fact[:trusted]
      end
      [ facts, references.all? { |reference| projects.key?(repository_for(reference)) }, associations ]
    end

    def identities_for_feature_intent(feature_intent_id)
      feature_associations(feature_intent_id).filter_map { |association| identity_for(association) }
    end

    def feature_associations(feature_intent_id)
      load_feature_associations.fetch(feature_intent_id, []).map do |association|
        association.except(:paths).merge(provenance: "Paid feature intent linkage")
      end
    end

    def fact_count
      @facts_by_project_id.values.flatten.count { |fact| !fact[:is_pull_request] && fact[:trusted] }
    end

    private

    attr_reader :project

    def projects_for(references)
      repositories = references.map { |reference| repository_for(reference) }.uniq
      missing = repositories - @projects_by_repository.keys
      load_projects(missing)
      @projects_by_repository.slice(*repositories)
    end

    def projects_for_ids(ids)
      missing = ids - @projects_by_id.keys
      Project.where(account_id: project.account_id, id: missing).find_each do |candidate|
        remember_project(candidate)
      end
      @projects_by_id.values_at(*ids).compact
    end

    def load_projects(repositories)
      return if repositories.empty?

      owners, repos = repositories.map { |repository| repository.split("/", 2) }.transpose
      Project.where(account_id: project.account_id, owner: owners, repo: repos).find_each do |candidate|
        remember_project(candidate) if repositories.include?(candidate.full_name)
      end
    end

    def remember_project(candidate)
      @projects_by_id[candidate.id] = candidate
      @projects_by_repository[candidate.full_name] = candidate
    end

    def facts_for(projects)
      project_ids = projects.map(&:id)
      missing = project_ids - @facts_by_project_id.keys
      load_facts(missing) if missing.any?
      project_ids.flat_map { |project_id| @facts_by_project_id.fetch(project_id) }
    end

    def load_facts(project_ids)
      project_ids.each { |project_id| @facts_by_project_id[project_id] = [] }
      Issue.where(project_id: project_ids).where.not(github_number: nil).pluck(*ISSUE_COLUMNS).each do |values|
        fact = fact_for(values)
        @facts_by_project_id.fetch(fact[:project_id]) << fact
      end
    end

    def fact_for(values)
      attributes = ISSUE_COLUMNS.zip(values).to_h
      candidate_project = @projects_by_id.fetch(attributes[:project_id])
      attributes.merge(
        repository: candidate_project.full_name,
        revision: attributes[:github_updated_at]&.iso8601,
        trusted: trusted?(candidate_project, attributes[:github_creator_login])
      ).except(:github_updated_at, :github_creator_login).tap do |fact|
        fact[:number] = fact.delete(:github_number)
        fact[:state] = fact.delete(:github_state)
      end
    end

    def trusted?(candidate_project, login)
      if candidate_project.upstream_pr_target?
        candidate_project.trusted_upstream_issue_author?(login)
      else
        candidate_project.trusted_github_author?(login)
      end
    end

    def backlink_associations(path)
      facts_for([ project ]).filter_map do |fact|
        next if fact[:is_pull_request] || !fact[:trusted]
        next unless relationship_text(fact[:body]).match?(artifact_path_pattern(path))

        association_for(fact, "exact artifact backlink")
      end
    end

    def manifest_associations(path)
      load_feature_associations.values.flatten.filter_map do |association|
        association.except(:paths) if association[:paths].include?(path)
      end
    end

    def load_feature_associations
      return @feature_associations if defined?(@feature_associations)

      @feature_associations = Hash.new { |hash, key| hash[key] = [] }
      rows = FeatureIntentIssue.joins(:feature_intent, issue: :project)
        .where(feature_intents: { project_id: project.id }, projects: { account_id: project.account_id })
        .pluck("feature_intent_issues.feature_intent_id", "feature_intents.design_document_paths", *issue_columns)
      rows.each do |feature_intent_id, paths, *values|
        fact = fact_for(values)
        @feature_associations[feature_intent_id] << association_for(fact, "canonical issue-tree manifest").merge(paths: Array(paths))
      end
      @feature_associations
    end

    def association_for(fact, provenance)
      {
        repository: fact[:repository], number: fact[:number], revision: fact[:revision],
        provenance:, project_id: fact[:project_id]
      }
    end

    def issue_columns = ISSUE_COLUMNS.map { |column| "issues.#{column}" }

    def identity_for(association)
      "#{association[:repository]}##{association[:number]}" if association[:number]
    end

    def repository_for(reference) = reference.split("#", 2).first

    def artifact_path_pattern(path) = /(?<![\w.\/-])#{Regexp.escape(path)}(?![\w.\/-])/

    def relationship_text(body)
      ReconcileDesignArtifactsJob.relationship_text(body)
    end
  end
end
