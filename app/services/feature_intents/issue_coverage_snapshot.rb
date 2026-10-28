# frozen_string_literal: true

module FeatureIntents
  # A reconciliation execution reads each authorized project's minimal issue
  # facts once. It intentionally converts query rows to hashes so no Active
  # Record association graph outlives the query.
  # @spec DESIGN-RECONCILIATION-001
  class IssueCoverageSnapshot
    ISSUE_COLUMNS = %i[github_number github_state title body github_updated_at is_pull_request github_creator_login].freeze

    def initialize(project:)
      @project = project
      @projects_by_name = { project.full_name => project }
      @facts_by_project_id = {}
      @artifact_issues = {}
    end

    def prepare!(artifacts:, pull_request_numbers: [])
      projects_for(artifacts.flat_map { |artifact| artifact.fetch(:related_issues) })
      load_facts(@projects_by_name.values)
      load_artifact_issues(pull_request_numbers)
      load_manifest_associations
      self
    end

    def projects_for(references)
      names = (references.map { |reference| repository_for(reference) } + [ project.full_name ]).uniq
      load_authorized_projects(names)
      @projects_by_name.slice(*names)
    end

    def facts_for(projects)
      selected = projects.uniq
      return [] if selected.empty?
      return facts_for_project(selected.first) if selected.one?

      selected.flat_map { |project| facts_for_project(project) }
    end

    def exact_backlinks(artifact)
      facts_for_project(project).filter_map do |issue|
        next unless issue[:body].to_s.include?(artifact[:path])
        next unless relationship_text(issue[:body]).match?(artifact_path_pattern(artifact.fetch(:path)))

        association_for(issue, "exact artifact backlink")
      end
    end

    def manifest_associations(artifact)
      @manifest_associations_by_path.fetch(artifact[:path], [])
    end

    def linked_issue_associations(feature_intent_id)
      @linked_issues_by_feature_intent.fetch(feature_intent_id, [])
    end

    def artifact_issue(number)
      @artifact_issues[number]
    end

    def issue_fact_count = @facts_by_project_id.values.sum(&:size)

    private

    attr_reader :project

    def load_authorized_projects(names)
      missing = names - @projects_by_name.keys
      return if missing.empty?

      owners, repositories = missing.map { |name| name.split("/", 2) }.transpose
      Project.where(account_id: project.account_id, owner: owners, repo: repositories).find_each do |candidate|
        @projects_by_name[candidate.full_name] = candidate if missing.include?(candidate.full_name)
      end
    end

    def load_facts(projects)
      projects.each { |candidate| facts_for_project(candidate) }
    end

    def facts_for_project(candidate)
      @facts_by_project_id[candidate.id] ||= Issue.where(project: candidate).where.not(github_number: nil)
        .pluck(*ISSUE_COLUMNS).filter_map do |number, state, title, body, updated_at, pull_request, creator|
          next if pull_request || !trusted?(candidate, creator)

          { repository: candidate.full_name, number:, state:, title:, body:, revision: updated_at&.iso8601 }
        end
    end

    def trusted?(candidate, creator)
      if candidate.upstream_pr_target?
        candidate.trusted_upstream_issue_author?(creator)
      else
        candidate.trusted_github_author?(creator)
      end
    end

    def load_artifact_issues(numbers)
      missing = numbers.uniq - @artifact_issues.keys
      return if missing.empty?

      Issue.where(project:, github_number: missing).pluck(:github_number, :body).each do |number, body|
        @artifact_issues[number] = { body: }
      end
    end

    def load_manifest_associations
      return if defined?(@manifest_associations_by_path)

      paths_by_feature_intent = FeatureIntent.where(project:).pluck(:id, :design_document_paths).to_h
      @manifest_associations_by_path = Hash.new { |hash, key| hash[key] = [] }
      @linked_issues_by_feature_intent = Hash.new { |hash, key| hash[key] = [] }
      return if paths_by_feature_intent.empty?

      FeatureIntentIssue.joins(issue: :project).where(feature_intent_id: paths_by_feature_intent.keys)
        .pluck("feature_intent_issues.feature_intent_id", "projects.owner", "projects.repo", "issues.github_number", "issues.github_updated_at")
        .each do |feature_intent_id, owner, repo, number, updated_at|
          association = { repository: "#{owner}/#{repo}", number:, revision: updated_at&.iso8601, project: nil }
          @linked_issues_by_feature_intent[feature_intent_id] << association.merge(provenance: "Paid feature intent linkage")
          Array(paths_by_feature_intent.fetch(feature_intent_id)).each do |path|
            @manifest_associations_by_path[path] << association.merge(provenance: "canonical issue-tree manifest")
          end
        end
    end

    def association_for(issue, provenance)
      { repository: issue[:repository], number: issue[:number], revision: issue[:revision], provenance:, project: nil }
    end

    def repository_for(reference)
      reference.split("#", 2).first
    end

    def relationship_text(body)
      ReconcileDesignArtifactsJob.relationship_text(body)
    end

    def artifact_path_pattern(path)
      /(?<![\w.\/-])#{Regexp.escape(path)}(?![\w.\/-])/
    end
  end
end
