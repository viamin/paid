# frozen_string_literal: true

module FeatureIntents
  # A short-lived, plain-data view of issue evidence for one reconciliation
  # execution. It intentionally owns no ORM issue graph and is never shared
  # between executions, so every run reads its own current synchronized facts.
  # @spec DESIGN-RECONCILIATION-001
  class IssueCoverageSnapshot
    def initialize(project:, relationship_text:)
      @project = project
      @relationship_text = relationship_text
      @projects_by_id = { project.id => project }
      @projects_by_name = { project.full_name => project }
      @facts_by_project_id = {}
      @manifest_associations_by_path = nil
    end

    def coverage_for(artifact)
      references = artifact.fetch(:related_issues)
      projects = projects_for(references)
      associations = Array(artifact[:associated_issues]) + structural_associations(artifact)
      association_projects = projects_for_ids(associations.filter_map { |association| association[:project_id] || association[:project]&.id }).values

      [
        facts_for((projects.values + association_projects).uniq),
        references.all? { |reference| projects.key?(repository_for(reference)) },
        associations
      ]
    end

    def issue_fact_count
      @facts_by_project_id.values.sum(&:size)
    end

    private

    attr_reader :project, :projects_by_id, :projects_by_name

    def structural_associations(artifact)
      exact_backlinks(artifact) + manifest_associations(artifact.fetch(:path))
    end

    def exact_backlinks(artifact)
      facts_for([ project ]).filter_map do |issue|
        next unless explicit_artifact_backlink?(issue, artifact)

        association_for(issue, "exact artifact backlink")
      end
    end

    def explicit_artifact_backlink?(issue, artifact)
      relationship_text(issue[:body]).match?(artifact_path_pattern(artifact.fetch(:path)))
    end

    def artifact_path_pattern(path)
      /(?<![\w.\/-])#{Regexp.escape(path)}(?![\w.\/-])/
    end

    def manifest_associations(path)
      manifest_associations_by_path.fetch(path, [])
    end

    def manifest_associations_by_path
      @manifest_associations_by_path ||= begin
        paths_by_intent = FeatureIntent.where(project:).pluck(:id, :design_document_paths).to_h
        links_by_intent = feature_intent_links(paths_by_intent.keys)

        paths_by_intent.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(intent_id, paths), associations|
          Array(paths).each do |path|
            associations[path].concat(links_by_intent.fetch(intent_id, []))
          end
        end
      end
    end

    def feature_intent_links(intent_ids)
      return {} if intent_ids.empty?

      rows = FeatureIntentIssue.joins(issue: :project).where(feature_intent_id: intent_ids).pluck(
        :feature_intent_id, "issues.github_number", "issues.github_updated_at", "projects.id"
      )
      projects_for_ids(rows.map(&:fourth)).then do |projects|
        rows.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(intent_id, number, revision, project_id), links|
          linked_project = projects[project_id]
          next unless linked_project && number

          links[intent_id] << {
            repository: linked_project.full_name, number:, revision: revision&.iso8601,
            provenance: "canonical issue-tree manifest", project_id:
          }
        end
      end
    end

    def association_for(issue, provenance)
      {
        repository: project_for(issue).full_name, number: issue[:number], revision: issue[:revision], provenance:,
        project_id: issue[:project_id]
      }
    end

    def projects_for(references)
      repositories = references.map { |reference| repository_for(reference) }.uniq
      load_projects(repositories - [ project.full_name ])
      ([ project.full_name ] + repositories).uniq.filter_map do |repository|
        [ repository, projects_by_name[repository] ] if projects_by_name.key?(repository)
      end.to_h
    end

    def projects_for_ids(ids)
      load_projects_by_id(ids)
      ids.filter_map { |id| [ id, projects_by_id[id] ] if projects_by_id.key?(id) }.to_h
    end

    def load_projects(repositories)
      return if repositories.empty?

      owners, repos = repositories.map { |repository| repository.split("/", 2) }.transpose
      register_projects(Project.where(account_id: project.account_id, owner: owners, repo: repos))
    end

    def load_projects_by_id(ids)
      missing_ids = ids.uniq - projects_by_id.keys
      return if missing_ids.empty?

      register_projects(Project.where(account_id: project.account_id, id: missing_ids))
    end

    def register_projects(records)
      records.each do |record|
        projects_by_id[record.id] = record
        projects_by_name[record.full_name] = record
      end
    end

    def facts_for(projects)
      projects.flat_map { |covered_project| facts_for_project(covered_project) }
    end

    def facts_for_project(covered_project)
      @facts_by_project_id[covered_project.id] ||= Issue.where(project_id: covered_project.id).where.not(github_number: nil).pluck(
        :project_id, :github_number, :github_state, :title, :body, :github_updated_at, :is_pull_request, :github_creator_login
      ).filter_map do |project_id, number, state, title, body, updated_at, pull_request, creator_login|
        next if pull_request || !trusted?(covered_project, creator_login)

        {
          project_id:, repository: covered_project.full_name, number:, state:, title:, body:,
          revision: updated_at&.iso8601
        }.freeze
      end.freeze
    end

    def trusted?(covered_project, creator_login)
      if covered_project.upstream_pr_target?
        covered_project.trusted_upstream_issue_author?(creator_login)
      else
        covered_project.trusted_github_author?(creator_login)
      end
    end

    def project_for(issue)
      projects_by_id.fetch(issue[:project_id])
    end

    def repository_for(reference)
      reference.split("#", 2).first
    end

    def relationship_text(body)
      @relationship_text.call(body)
    end
  end
end
