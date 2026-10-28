# frozen_string_literal: true

module FeatureIntents
  # A reconciliation execution reads a fixed, minimal issue projection once.
  # The projection is intentionally ephemeral: it is prepared for one job and
  # never survives to a later revision or execution.
  class DesignArtifactIssueCoverage
    def initialize(project:, relationship_text:)
      @project = project
      @relationship_text = relationship_text
    end

    # @spec DESIGN-RECONCILIATION-001
    def prepare!(artifacts)
      @projects_by_repository = authorized_projects(artifacts).index_by { |candidate| candidate.full_name }
      @projects_by_repository[project.full_name] = project
      @links_by_feature_intent = feature_intent_links
      @facts_by_id = issue_facts.index_by { |fact| fact.fetch(:id) }
      @facts_by_project_id = @facts_by_id.values.group_by { |fact| fact.fetch(:project_id) }
      self
    end

    def coverage_for(artifact)
      references = artifact.fetch(:related_issues)
      projects = references.to_h { |reference| [ repository_for(reference), @projects_by_repository[repository_for(reference)] ] }.compact
      associations = Array(artifact[:associated_issues]) + structural_associations(artifact)
      project_ids = [ project.id ] + projects.values.map(&:id) + associations.filter_map { |association| association[:project_id] }

      [ project_ids.uniq.flat_map { |id| @facts_by_project_id.fetch(id, []) },
        references.all? { |reference| projects.key?(repository_for(reference)) }, associations ]
    end

    def issue_count = @facts_by_id&.size || 0

    private

    attr_reader :project, :relationship_text

    def authorized_projects(artifacts)
      repositories = artifacts.flat_map { |artifact| artifact.fetch(:related_issues) }.map { |reference| repository_for(reference) }.uniq
      external = repositories - [ project.full_name ]
      return [] if external.empty?

      owners, repositories_by_name = external.map { |name| name.split("/", 2) }.transpose
      Project.where(account_id: project.account_id, owner: owners, repo: repositories_by_name).select(:id, :owner, :repo).to_a.select do |candidate|
        external.include?(candidate.full_name)
      end
    end

    def feature_intent_links
      paths_by_intent = FeatureIntent.where(project:).pluck(:id, :design_document_paths).to_h
      return {} if paths_by_intent.empty?

      FeatureIntentIssue.joins(issue: :project)
        .where(feature_intent_id: paths_by_intent.keys, projects: { account_id: project.account_id })
        .pluck(:feature_intent_id, :issue_id)
        .group_by(&:first)
        .transform_values { |links| { paths: paths_by_intent.fetch(links.first.first), issue_ids: links.map(&:last) } }
    end

    def issue_facts
      project_ids = @projects_by_repository.values.map(&:id)
      linked_issue_ids = @links_by_feature_intent.values.flat_map { |links| links.fetch(:issue_ids) }
      scope = Issue.where(project_id: project_ids).or(Issue.where(id: linked_issue_ids))
        .preload(:project).where.not(github_number: nil)

      scope.select(:id, :project_id, :github_number, :github_state, :title, :body, :github_updated_at, :is_pull_request, :github_creator_login)
        .filter_map { |issue| fact_for(issue) }
    end

    def fact_for(issue)
      return if issue.is_pull_request? || !issue.trusted?

      {
        id: issue.id, project_id: issue.project_id, repository: issue.project.full_name,
        number: issue.github_number, state: issue.github_state, title: issue.title,
        body: issue.body, revision: issue.github_updated_at&.iso8601
      }
    end

    def structural_associations(artifact)
      feature_intent_associations(artifact) + exact_backlinks(artifact) + manifest_associations(artifact)
    end

    def feature_intent_associations(artifact)
      links = @links_by_feature_intent[artifact[:feature_intent_id]]
      return [] unless links

      links.fetch(:issue_ids).filter_map { |issue_id| association_for(@facts_by_id[issue_id], "Paid feature intent linkage") }
    end

    def exact_backlinks(artifact)
      @facts_by_project_id.fetch(project.id, []).filter_map do |fact|
        next unless relationship_text.call(fact[:body]).match?(artifact_path_pattern(artifact.fetch(:path)))

        association_for(fact, "exact artifact backlink")
      end
    end

    def manifest_associations(artifact)
      @links_by_feature_intent.values.filter_map do |links|
        next unless artifact[:path].in?(links.fetch(:paths))

        links.fetch(:issue_ids).filter_map { |issue_id| association_for(@facts_by_id[issue_id], "canonical issue-tree manifest") }
      end.flatten
    end

    def association_for(fact, provenance)
      return unless fact

      fact.slice(:repository, :number, :revision, :project_id).merge(provenance:)
    end

    def artifact_path_pattern(path)
      /(?<![\w.\/-])#{Regexp.escape(path)}(?![\w.\/-])/
    end

    def repository_for(reference)
      reference.split("#", 2).first
    end
  end
end
