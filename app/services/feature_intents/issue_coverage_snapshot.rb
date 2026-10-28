# frozen_string_literal: true

module FeatureIntents
  # A short-lived, minimal read model for one reconciliation execution.
  # @spec DESIGN-RECONCILIATION-001
  class IssueCoverageSnapshot
    IssueFact = Data.define(:id, :project, :number, :state, :title, :body, :revision, :pull_request, :trusted)

    def initialize(project)
      @project = project
      @projects_by_repository = { project.full_name => project }
      @facts_by_project_id = {}
      @facts_by_id = {}
    end

    def projects_for(repositories)
      repositories = [ @project.full_name, *repositories ].uniq
      load_projects(repositories)
      repositories.filter_map { |repository| @projects_by_repository[repository] }
    end

    def issue(project, number)
      facts_for([ project ]).find { |fact| fact.number == number }
    end

    def issue_facts(projects)
      facts_for(projects).reject { |fact| fact.pull_request || !fact.trusted }
    end

    def exact_backlinks(path, relationship_text:, pattern:)
      issue_facts([ @project ]).filter_map do |fact|
        next unless fact.body.to_s.include?(path)
        next unless relationship_text.call(fact.body).match?(pattern)

        association_for(fact, "exact artifact backlink")
      end
    end

    def associations_for(feature_intent_id)
      load_feature_intent_associations
      @associations_by_feature_intent_id.fetch(feature_intent_id, [])
    end

    def manifest_associations(path)
      load_feature_intent_associations
      @manifest_associations_by_path.fetch(path, [])
    end

    def issue_count = @facts_by_project_id.values.sum(&:size)

    private

    def facts_for(projects)
      projects.flat_map { |project| load_facts(project) }
    end

    def load_projects(repositories)
      missing = repositories.uniq - @projects_by_repository.keys
      return if missing.empty?

      owners, repos = missing.map { |repository| repository.split("/", 2) }.transpose
      Project.where(account_id: @project.account_id, owner: owners, repo: repos)
        .select(:id, :account_id, :owner, :repo, :allowed_github_usernames, :pr_target, :github_installation_id)
        .find_each do |project|
        @projects_by_repository[project.full_name] = project if missing.include?(project.full_name)
      end
    end

    def load_facts(project)
      @facts_by_project_id[project.id] ||= Issue.where(project_id: project.id).where.not(github_number: nil).pluck(
        :id, :github_number, :github_state, :title, :body, :github_updated_at, :is_pull_request, :github_creator_login
      ).map do |id, number, state, title, body, updated_at, pull_request, creator_login|
        fact = IssueFact.new(
          id:, project:, number:, state:, title:, body:, revision: updated_at&.iso8601, pull_request:,
          trusted: trusted?(project, creator_login)
        )
        @facts_by_id[id] = fact
        fact
      end
    end

    def trusted?(project, creator_login)
      project.upstream_pr_target? ?
        project.trusted_upstream_issue_author?(creator_login) :
        project.trusted_github_author?(creator_login)
    end

    def load_feature_intent_associations
      return if defined?(@associations_by_feature_intent_id)

      links = FeatureIntentIssue.joins(:feature_intent).where(feature_intents: { project_id: @project.id })
        .pluck(:feature_intent_id, :issue_id)
      load_linked_issue_projects(links)
      link_associations = links.filter_map do |feature_intent_id, issue_id|
        fact = @facts_by_id[issue_id]
        [ feature_intent_id, association_for(fact, "Paid feature intent linkage") ] if fact
      end
      @associations_by_feature_intent_id = link_associations.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
      @manifest_associations_by_path = FeatureIntent.where(project: @project).pluck(:id, :design_document_paths)
        .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(id, paths), associations|
          manifest_links = @associations_by_feature_intent_id.fetch(id, []).map do |association|
            association.merge(provenance: "canonical issue-tree manifest")
          end
          Array(paths).each { |path| associations[path].concat(manifest_links) }
        end
    end

    def load_linked_issue_projects(links)
      issue_ids = links.map(&:last).uniq
      return if issue_ids.empty?

      linked_projects = projects_for(Issue.where(id: issue_ids).joins(:project).where(projects: { account_id: @project.account_id })
        .pluck("projects.owner", "projects.repo").map { |owner, repo| "#{owner}/#{repo}" })
      facts_for(linked_projects)
    end

    def association_for(fact, provenance)
      return unless fact&.number

      { repository: fact.project.full_name, number: fact.number, revision: fact.revision, provenance:, project: fact.project }
    end
  end
end
