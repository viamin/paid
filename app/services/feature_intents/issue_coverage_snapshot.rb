# frozen_string_literal: true

require "set"

module FeatureIntents
  # A reconciliation execution owns this bounded snapshot. It intentionally
  # keeps only the fields required to assess design-artifact coverage, never
  # Active Record association graphs.
  # @spec DESIGN-RECONCILIATION-001
  class IssueCoverageSnapshot
    IssueFact = Data.define(:id, :project_id, :number, :state, :title, :body, :revision, :pull_request, :creator_login)

    def initialize(project:)
      @project = project
      @projects = { project.full_name => project }
      @unavailable_repositories = Set.new
      @issue_facts = {}
      @coverage_facts = {}
      @feature_intents = nil
      @feature_issue_ids = nil
      @manifest_feature_ids_by_path = nil
    end

    def issue_for(number)
      issue_facts_for(project).find { |issue| issue.number == number }
    end

    def coverage_for(artifact:, artifact_backlink:)
      references = artifact.fetch(:related_issues)
      associations = Array(artifact[:associated_issues]) + structural_associations(artifact, artifact_backlink:)
      repositories = [ project.full_name ] + references.map { |reference| repository_for(reference) } + associations.map { |association| association[:repository] }
      projects = projects_for(repositories)

      [ coverage_facts_for(projects.values), references.all? { |reference| projects.key?(repository_for(reference)) }, associations ]
    end

    def linked_associations(feature_intent_id, provenance:)
      linked_issue_facts(feature_intent_id).filter_map { |issue| association_for(issue, provenance) }
    end

    def linked_identities(feature_intent_id)
      linked_issue_facts(feature_intent_id).filter_map { |issue| identity_for(issue) }
    end

    private

    attr_reader :project

    def structural_associations(artifact, artifact_backlink:)
      exact_backlinks(artifact, artifact_backlink:) + manifest_associations(artifact)
    end

    def exact_backlinks(artifact, artifact_backlink:)
      issue_facts_for(project).filter_map do |issue|
        next if issue.pull_request || !trusted?(issue, project)
        next unless artifact_backlink.call(issue.body, artifact)

        association_for(issue, "exact artifact backlink")
      end
    end

    def manifest_associations(artifact)
      manifest_feature_ids_by_path.fetch(artifact[:path], []).flat_map do |feature_intent_id|
        linked_associations(feature_intent_id, provenance: "canonical issue-tree manifest")
      end
    end

    def linked_issue_facts(feature_intent_id)
      feature_issue_ids.fetch(feature_intent_id, []).filter_map { |issue_id| issue_by_id[issue_id] }
    end

    def feature_issue_ids
      @feature_issue_ids ||= begin
        ids = feature_intents.map(&:first)
        FeatureIntentIssue.where(feature_intent_id: ids).pluck(:feature_intent_id, :issue_id)
          .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(feature_intent_id, issue_id), links|
            links[feature_intent_id] << issue_id
          end
      end
    end

    def manifest_feature_ids_by_path
      @manifest_feature_ids_by_path ||= feature_intents
        .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(id, paths), manifests|
          Array(paths).each { |path| manifests[path] << id }
        end
    end

    def feature_intents
      @feature_intents ||= FeatureIntent.where(project:).pluck(:id, :design_document_paths)
    end

    def issue_by_id
      @issue_by_id ||= issue_facts_for(project).index_by(&:id)
    end

    def projects_for(repositories)
      missing = repositories.uniq - @projects.keys - @unavailable_repositories.to_a
      return @projects.slice(*repositories) if missing.empty?

      Project.where(account_id: project.account_id, owner: missing.map { |name| name.split("/").first }, repo: missing.map { |name| name.split("/").last })
        .select(:id, :owner, :repo, :allowed_github_usernames, :github_installation_id, :pr_target)
        .find_each { |candidate| @projects[candidate.full_name] = candidate }
      @unavailable_repositories.merge(missing - @projects.keys)
      @projects.slice(*repositories)
    end

    def coverage_facts_for(projects)
      projects.flat_map { |candidate| coverage_facts_for_project(candidate) }
    end

    def coverage_facts_for_project(candidate)
      @coverage_facts[candidate.id] ||= issue_facts_for(candidate).filter_map do |issue|
        next if issue.pull_request || !trusted?(issue, candidate)

        {
          repository: candidate.full_name, number: issue.number, state: issue.state,
          title: issue.title, body: issue.body, revision: issue.revision
        }.freeze
      end.freeze
    end

    def issue_facts_for(candidate)
      @issue_facts[candidate.id] ||= Issue.where(project_id: candidate.id).where.not(github_number: nil)
        .pluck(:id, :project_id, :github_number, :github_state, :title, :body, :github_updated_at, :is_pull_request, :github_creator_login)
        .map do |id, project_id, number, state, title, body, updated_at, pull_request, creator_login|
          IssueFact.new(id:, project_id:, number:, state:, title:, body:, revision: updated_at&.iso8601, pull_request:, creator_login:).freeze
        end
    end

    def trusted?(issue, candidate)
      if candidate.upstream_pr_target?
        candidate.trusted_upstream_issue_author?(issue.creator_login)
      else
        candidate.trusted_github_author?(issue.creator_login)
      end
    end

    def association_for(issue, provenance)
      return unless issue.number

      { repository: repository_for_project(issue.project_id), number: issue.number, revision: issue.revision, provenance: }
    end

    def identity_for(issue)
      "#{repository_for_project(issue.project_id)}##{issue.number}" if issue.number
    end

    def repository_for_project(project_id)
      @projects.values.find { |candidate| candidate.id == project_id }&.full_name
    end

    def repository_for(reference)
      reference.split("#", 2).first
    end
  end
end
