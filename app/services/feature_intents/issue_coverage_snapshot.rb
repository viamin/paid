# frozen_string_literal: true

module FeatureIntents
  # A reconciliation run owns this snapshot. It intentionally retains only the
  # facts required for deterministic coverage, never Issue association graphs.
  # @spec DESIGN-RECONCILIATION-001
  class IssueCoverageSnapshot
    EMPTY = [].freeze

    Fact = Data.define(:project, :number, :state, :title, :body, :revision, :issue_fact) do
      def association(provenance)
        return unless number

        { repository: project.full_name, number:, revision: revision&.iso8601, provenance:, project: }
      end

      def identity
        "#{project.full_name}##{number}"
      end
    end

    def initialize(project:)
      @project = project
      @projects_by_id = { project.id => project }
      @projects_by_repository = { project.full_name => project }
      @facts_by_project_id = {}
    end

    def projects_for(references)
      repositories = (references.map { |reference| reference.split("#", 2).first } + [ project.full_name ]).uniq
      load_authorized_projects(repositories)
      @projects_by_repository.slice(*repositories)
    end

    def issue_facts(projects)
      facts_for(projects).map(&:issue_fact)
    end

    def exact_backlinks(artifact)
      facts_for([ @project ]).filter_map do |fact|
        fact.association("exact artifact backlink") if yield(fact.body)
      end
    end

    def manifest_associations(path)
      load_manifests
      @manifest_facts_by_intent_id.values_at(*intent_ids_for(path)).flatten.filter_map do |fact|
        fact.association("canonical issue-tree manifest")
      end
    end

    def feature_intent_identities(feature_intent_id)
      load_manifests
      @manifest_facts_by_intent_id.fetch(feature_intent_id, EMPTY).map(&:identity)
    end

    def feature_intent_associations(feature_intent_id, provenance:)
      load_manifests
      @manifest_facts_by_intent_id.fetch(feature_intent_id, EMPTY).filter_map { |fact| fact.association(provenance) }
    end

    def fact_count
      @facts_by_project_id.values.sum(&:size)
    end

    private

    attr_reader :project

    def facts_for(projects)
      load_issue_facts(projects)
      projects.flat_map { |covered_project| @facts_by_project_id.fetch(covered_project.id) }
    end

    def load_issue_facts(projects)
      unloaded = projects.reject { |covered_project| @facts_by_project_id.key?(covered_project.id) }
      return if unloaded.empty?

      unloaded.each { |covered_project| @facts_by_project_id[covered_project.id] = [] }
      Issue.where(project_id: unloaded.map(&:id)).where.not(github_number: nil)
        .pluck(:project_id, :github_number, :github_state, :title, :body, :github_updated_at, :is_pull_request, :github_creator_login)
        .each do |project_id, number, state, title, body, revision, pull_request, creator_login|
          covered_project = @projects_by_id.fetch(project_id)
          next if pull_request || !trusted_author?(covered_project, creator_login)

          @facts_by_project_id.fetch(project_id) << fact_for(covered_project, number, state, title, body, revision)
        end
    end

    def trusted_author?(covered_project, creator_login)
      if covered_project.upstream_pr_target?
        covered_project.trusted_upstream_issue_author?(creator_login)
      else
        covered_project.trusted_github_author?(creator_login)
      end
    end

    def load_authorized_projects(repositories)
      missing = repositories - @projects_by_repository.keys
      return if missing.empty?

      owners, repos = missing.map { |name| name.split("/", 2) }.transpose
      Project.where(account_id: project.account_id, owner: owners, repo: repos).find_each do |covered_project|
        next unless missing.include?(covered_project.full_name)

        register_project(covered_project)
      end
    end

    def load_manifests
      return if defined?(@manifest_facts_by_intent_id)

      paths_by_intent_id = FeatureIntent.where(project:).pluck(:id, :design_document_paths).to_h
      @intent_ids_by_path = Hash.new { |hash, path| hash[path] = [] }
      paths_by_intent_id.each { |id, paths| Array(paths).each { |path| @intent_ids_by_path[path] << id } }
      @manifest_facts_by_intent_id = paths_by_intent_id.keys.index_with { EMPTY }
      load_manifest_facts(paths_by_intent_id.keys)
    end

    def load_manifest_facts(feature_intent_ids)
      rows = FeatureIntentIssue.joins(:issue).where(feature_intent_id: feature_intent_ids)
        .pluck(:feature_intent_id, "issues.project_id", "issues.github_number", "issues.github_updated_at")
      load_projects_by_id(rows.map { |_intent_id, project_id, *_| project_id }.uniq)
      @manifest_facts_by_intent_id = rows.group_by(&:first).transform_values do |intent_rows|
        intent_rows.filter_map do |_intent_id, project_id, number, revision|
          covered_project = @projects_by_id[project_id]
          fact_for(covered_project, number, nil, nil, nil, revision) if covered_project
        end
      end
    end

    def load_projects_by_id(ids)
      missing = ids - @projects_by_id.keys
      Project.where(id: missing).find_each { |covered_project| register_project(covered_project) } if missing.any?
    end

    def register_project(covered_project)
      @projects_by_id[covered_project.id] = covered_project
      @projects_by_repository[covered_project.full_name] = covered_project
    end

    def fact_for(covered_project, number, state, title, body, revision)
      Fact.new(
        covered_project, number, state, title, body, revision,
        { repository: covered_project.full_name, number:, state:, title:, body:, revision: revision&.iso8601 }.freeze
      )
    end

    def intent_ids_for(path)
      @intent_ids_by_path.fetch(path, EMPTY)
    end
  end
end
