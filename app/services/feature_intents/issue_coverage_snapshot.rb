# frozen_string_literal: true

module FeatureIntents
  # A short-lived, minimal projection of synchronized issue evidence for one
  # reconciliation execution. It intentionally retains facts, never Issue or
  # association graphs, and is rebuilt for every execution.
  # @spec DESIGN-RECONCILIATION-003
  class IssueCoverageSnapshot
    Fact = Data.define(:id, :project_id, :repository, :number, :state, :title, :body, :revision, :pull_request, :trusted)
    CoverageProject = Data.define(:id, :repository, :owner, :upstream, :trusted_logins) do
      def trusted?(login)
        return false if login.blank?

        trusted_logins.include?(login.downcase) || (upstream && owner.casecmp?(login))
      end
    end

    RELATIONSHIP_LINE_PATTERN = /^\s*(?:[-*]\s+)?(?:\*\*)?(?:implements|closes|fixes|resolves|tracks|depends on|blocked by|related issues?)(?:\s*:)?(?:\*\*)?\s*:?\s+(.+)$/i
    RELATIONSHIP_HEADING_PATTERN = /^\s{0,3}\#{1,6}\s+(?:\*\*)?(?:implements|closes|fixes|resolves|tracks|depends on|blocked by|related issues?)(?:\*\*)?\s*#*\s*$/i
    MARKDOWN_HEADING_PATTERN = /^\s{0,3}\#{1,6}\s+/

    def initialize(project:, artifacts:)
      @project = project
      @artifacts = artifacts
      @manifest_paths = manifest_paths
      @projects = coverage_projects
      @facts = issue_facts
      @facts_by_id = facts.index_by(&:id)
      @fact_hashes = facts.to_h { |fact| [ fact.id, fact.to_h.slice(:repository, :number, :state, :title, :body, :revision) ] }
      @backlinks = backlinks
      @manifest_associations = manifest_associations
    end

    def coverage_for(artifact)
      associations = Array(artifact[:associated_issues]) + backlinks.fetch(artifact[:path], []) + manifest_associations.fetch(artifact[:path], [])
      project_ids = [ project.id ] + project_ids_for(artifact.fetch(:related_issues)) + associations.filter_map { |association| project_id_for(association) }
      [ facts_for(project_ids), coverage_complete?(artifact.fetch(:related_issues)), associations ]
    end

    def fact_count = facts.count { |fact| usable?(fact) }

    private

    attr_reader :project, :artifacts, :projects, :facts, :facts_by_id, :fact_hashes

    def manifest_paths
      intents = FeatureIntent.where(project:).pluck(:id, :design_document_paths)
      paths_by_intent = intents.to_h
      return {} if paths_by_intent.empty?

      FeatureIntentIssue.where(feature_intent_id: paths_by_intent.keys).pluck(:feature_intent_id, :issue_id)
        .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(intent_id, issue_id), paths|
          paths[issue_id].concat(Array(paths_by_intent.fetch(intent_id)))
        end
    end

    def coverage_projects
      repositories = artifacts.flat_map { |artifact| artifact.fetch(:related_issues) }.map { |reference| repository_for(reference) }.uniq
      scope = Project.where(account_id: project.account_id)
      candidates = scope.where(id: manifest_project_ids).or(projects_for_repositories(scope, repositories))
        .select(:id, :owner, :repo, :pr_target, :allowed_github_usernames, :github_installation_id)
      candidates.to_h { |candidate| [ candidate.id, coverage_project(candidate) ] }.merge(project.id => coverage_project(project))
    end

    def manifest_project_ids
      return [] if manifest_paths.empty?

      Issue.where(id: manifest_paths.keys).pluck(:project_id).uniq
    end

    def projects_for_repositories(scope, repositories)
      repositories.reduce(scope.none) do |matches, repository|
        owner, repo = repository.split("/", 2)
        matches.or(scope.where(owner:, repo:))
      end
    end

    def coverage_project(record)
      logins = Array(record.allowed_github_usernames).filter_map { |login| login.to_s.downcase.presence }
      logins << Github::AppRegistry.bot_login.downcase if record.github_installation_id.present?
      CoverageProject.new(id: record.id, repository: record.full_name, owner: record.owner, upstream: record.upstream_pr_target?, trusted_logins: logins.uniq)
    end

    def issue_facts
      Issue.where(project_id: projects.keys).where.not(github_number: nil).pluck(
        :id, :project_id, :github_number, :github_state, :title, :body, :github_updated_at, :is_pull_request, :github_creator_login
      ).filter_map do |id, project_id, number, state, title, body, updated_at, pull_request, creator|
        coverage_project = projects.fetch(project_id)
        Fact.new(id:, project_id:, repository: coverage_project.repository, number:, state:, title:, body:, revision: updated_at&.iso8601,
          pull_request:, trusted: coverage_project.trusted?(creator))
      end
    end

    def backlinks
      local_facts = facts.select { |fact| fact.project_id == project.id && usable?(fact) }
      paths = artifacts.to_h { |artifact| [ artifact[:path], artifact_path_pattern(artifact[:path]) ] }
      local_facts.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |fact, index|
        text = relationship_text(fact.body)
        paths.each do |path, pattern|
          index[path] << association_for(fact, "exact artifact backlink") if text.match?(pattern)
        end
      end
    end

    def manifest_associations
      manifest_paths.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(issue_id, paths), index|
        fact = facts_by_id[issue_id]
        next unless fact && usable?(fact)

        paths.each { |path| index[path] << association_for(fact, "canonical issue-tree manifest") }
      end
    end

    def facts_for(project_ids)
      facts.select { |fact| fact.project_id.in?(project_ids) && usable?(fact) }.map { |fact| fact_hashes.fetch(fact.id) }
    end

    def usable?(fact) = !fact.pull_request && fact.trusted

    def coverage_complete?(references)
      references.all? { |reference| projects.values.any? { |coverage| coverage.repository == repository_for(reference) } }
    end

    def project_ids_for(references)
      references.filter_map do |reference|
        projects.values.find { |coverage| coverage.repository == repository_for(reference) }&.id
      end
    end

    def project_id_for(association)
      projects.values.find { |coverage| coverage.repository == association[:repository] }&.id
    end

    def association_for(fact, provenance)
      { repository: fact.repository, number: fact.number, revision: fact.revision, provenance: }
    end

    def repository_for(reference) = reference.split("#", 2).first

    def artifact_path_pattern(path) = /(?<![\w.\/-])#{Regexp.escape(path)}(?![\w.\/-])/

    def relationship_text(body)
      in_relationship_section = false
      body.to_s.each_line.filter_map do |line|
        if line.match?(RELATIONSHIP_HEADING_PATTERN)
          in_relationship_section = true
          next
        end
        in_relationship_section = false if line.match?(MARKDOWN_HEADING_PATTERN)
        in_relationship_section ? line : line[RELATIONSHIP_LINE_PATTERN, 1]
      end.join("\n")
    end
  end
end
