# frozen_string_literal: true

module FeatureIntents
  # A reconciliation-local projection of coverage evidence. It keeps no Issue
  # records or association graphs, and is discarded with the job instance.
  # @spec DESIGN-RECONCILIATION-003
  class IssueCoverageSnapshot
    ISSUE_FIELDS = %i[project_id github_number github_state title body github_updated_at is_pull_request github_creator_login].freeze

    def initialize(project:, relationship_text:)
      @project = project
      @relationship_text = relationship_text
      @projects_by_id = { project.id => project }
      @projects_by_repository = { project.full_name => project }
      @facts_by_project_id = {}
      @links_by_feature_intent_id = {}
      @manifest_associations_by_path = Hash.new { |hash, key| hash[key] = [] }
    end

    def prepare(artifacts)
      register_reference_projects(artifacts.flat_map { |artifact| artifact.fetch(:related_issues) })
      load_manifest_associations
      register_association_projects(artifacts.flat_map { |artifact| Array(artifact[:associated_issues]) })
      load_issue_facts
    end

    def prepare_feature_intents(feature_intent_ids)
      load_feature_intent_links(feature_intent_ids)
      load_issue_facts
    end

    def issue_facts(references:, associations:)
      project_ids = [ project.id ]
      project_ids.concat(references.filter_map { |reference| project_for_reference(reference)&.id })
      project_ids.concat(associations.filter_map { |association| association[:project_id] })
      project_ids.uniq.flat_map { |project_id| @facts_by_project_id.fetch(project_id, []) }
    end

    def coverage_complete?(references)
      references.all? { |reference| project_for_reference(reference).present? }
    end

    def structural_associations(path)
      exact_backlinks(path) + @manifest_associations_by_path.fetch(path, [])
    end

    def links_for(feature_intent_id)
      @links_by_feature_intent_id.fetch(feature_intent_id, [])
    end

    private

    attr_reader :project, :relationship_text

    def register_reference_projects(references)
      repositories = references.map { |reference| reference.split("#", 2).first }.uniq
      missing = repositories.reject { |repository| @projects_by_repository.key?(repository) }
      return if missing.empty?

      conditions = missing.map { "(owner = ? AND repo = ?)" }.join(" OR ")
      values = missing.flat_map { |repository| repository.split("/", 2) }
      register_projects(Project.where(account_id: project.account_id).where(conditions, *values))
    end

    def register_association_projects(associations)
      project_ids = associations.filter_map { |association| association[:project_id] }.uniq
      register_projects(Project.where(account_id: project.account_id, id: project_ids)) if project_ids.any?
    end

    def register_projects(projects)
      projects.each do |candidate|
        @projects_by_id[candidate.id] = candidate
        @projects_by_repository[candidate.full_name] = candidate
      end
    end

    def load_manifest_associations
      manifests = FeatureIntent.where(project:).pluck(:id, :design_document_paths)
      load_feature_intent_links(manifests.map(&:first))
      manifests.each do |feature_intent_id, paths|
        Array(paths).each do |path|
          @manifest_associations_by_path[path].concat(links_for(feature_intent_id).map do |link|
            link.merge(provenance: "canonical issue-tree manifest")
          end)
        end
      end
    end

    def load_feature_intent_links(feature_intent_ids)
      ids = feature_intent_ids.compact.uniq - @links_by_feature_intent_id.keys
      return if ids.empty?

      rows = FeatureIntentIssue.joins(issue: :project).where(feature_intent_id: ids).pluck(
        :feature_intent_id, "issues.project_id", "projects.owner", "projects.repo", "issues.github_number", "issues.github_updated_at"
      )
      register_projects(Project.where(account_id: project.account_id, id: rows.map { |row| row[1] }.uniq))
      ids.each { |id| @links_by_feature_intent_id[id] = [] }
      rows.each do |feature_intent_id, project_id, owner, repo, number, updated_at|
        next unless @projects_by_id.key?(project_id) && number

        @links_by_feature_intent_id[feature_intent_id] << association(project_id:, owner:, repo:, number:, updated_at:)
      end
    end

    def load_issue_facts
      unloaded_ids = @projects_by_id.keys - @facts_by_project_id.keys
      return if unloaded_ids.empty?

      unloaded_ids.each { |project_id| @facts_by_project_id[project_id] = [] }
      Issue.where(project_id: unloaded_ids).where.not(github_number: nil).in_batches(of: 500) do |batch|
        batch.pluck(*ISSUE_FIELDS).each { |row| add_fact(*row) }
      end
    end

    def add_fact(project_id, number, state, title, body, updated_at, pull_request, creator_login)
      candidate_project = @projects_by_id.fetch(project_id)
      return if pull_request || !trusted?(candidate_project, creator_login)

      @facts_by_project_id.fetch(project_id) << {
        repository: candidate_project.full_name, number:, state:, title:, body:, revision: updated_at&.iso8601
      }
    end

    def trusted?(candidate_project, creator_login)
      if candidate_project.upstream_pr_target?
        candidate_project.trusted_upstream_issue_author?(creator_login)
      else
        candidate_project.trusted_github_author?(creator_login)
      end
    end

    def exact_backlinks(path)
      pattern = /(?<![\w.\/-])#{Regexp.escape(path)}(?![\w.\/-])/
      @facts_by_project_id.fetch(project.id, []).filter_map do |fact|
        next unless relationship_text.call(fact[:body]).match?(pattern)

        association(project_id: project.id, owner: project.owner, repo: project.repo, number: fact[:number], updated_at: fact[:revision])
          .merge(provenance: "exact artifact backlink")
      end
    end

    def association(project_id:, owner:, repo:, number:, updated_at:)
      revision = updated_at&.respond_to?(:iso8601) ? updated_at.iso8601 : updated_at
      { repository: "#{owner}/#{repo}", number:, revision:, project_id: }
    end

    def project_for_reference(reference)
      @projects_by_repository[reference.split("#", 2).first]
    end
  end
end
