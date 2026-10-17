# frozen_string_literal: true

module FeatureIntents
  # Reconciles one known design pull request using the synchronized local
  # issue mirror. GitHub synchronization is the authority for both inputs;
  # this job never makes write calls to GitHub.
  # @spec DESIGN-RECONCILIATION-001
  class ReconcileDesignArtifactsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    RDR_STATUS_PATTERN = /^\s*(?:\*\*)?status(?:\*\*)?\s*:\s*(?:\*\*)?(.+?)(?:\*\*)?\s*$/i
    RELATIONSHIP_LINE_PATTERN = /^\s*(?:[-*]\s+)?(?:\*\*)?(?:implements|closes|fixes|resolves|tracks|depends on|blocked by|related issues?)(?:\s*:)?(?:\*\*)?\s*:?\s+(.+)$/i
    RELATIONSHIP_HEADING_PATTERN = /^\s{0,3}\#{1,6}\s+(?:\*\*)?(?:implements|closes|fixes|resolves|tracks|depends on|blocked by|related issues?)(?:\*\*)?\s*#*\s*$/i
    MARKDOWN_HEADING_PATTERN = /^\s{0,3}\#{1,6}\s+/

    queue_as :maintenance

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: -> { "design_artifact_reconciliation_#{arguments.first}_#{arguments.second}" }
    )

    discard_on ActiveRecord::RecordNotFound

    def perform(project_id, pull_request_number = nil)
      @project = Project.find(project_id)
      return reconcile_project_artifacts unless pull_request_number

      design_pr = design_pull_request(pull_request_number)
      reconcile(artifact_for(design_pr), revision: design_pr.head_sha) if design_pr
    end

    private

    attr_reader :project

    def design_pull_request(pull_request_number)
      FeatureIntentDesignPr.joins(:feature_intent).includes(feature_intent: { issues: :project }).find_by(
        feature_intents: { project_id: project.id }, pull_request_number:
      )
    end

    def artifact_for(design_pr)
      issue = project_issue(design_pr.pull_request_number)
      {
        path: "pull/#{design_pr.pull_request_number}",
        revision: design_pr.head_sha,
        body: issue&.body,
        status: design_pr.draft? ? "draft" : nil,
        related_issues: explicit_references(issue&.body),
        stored_identities: design_pr.feature_intent.issues.map { |linked| identity_for(linked) },
        associated_issues: design_pr.feature_intent.issues.filter_map do |linked|
          association_for(linked, "Paid feature intent linkage")
        end,
        coverage_complete: issue.present? && design_pr.draft.in?([ true, false ])
      }
    end

    def project_issue(number)
      @project_issue ||= {}
      @project_issue[number] ||= project.issues.find_by(github_number: number)
    end

    def reconcile_rdr_artifacts
      artifacts = DiscoverRdrArtifacts.call(project:)
      artifacts.each do |artifact|
        reconcile(rdr_artifact(artifact), revision: artifact.revision, coverage_complete: !artifact.body.nil?)
      end
      resolve_removed_rdr_findings(artifacts) if rdr_directory_discovered?(artifacts)
    end

    def resolve_removed_rdr_findings(artifacts)
      convention = DiscoverRdrArtifacts.convention_for(project)
      PersistDesignArtifactFindings.resolve_removed_rdr_findings(
        project:, paths: artifacts.map(&:path), directory: convention.directory, file_pattern: convention.file_pattern
      )
    end

    def rdr_directory_discovered?(artifacts)
      artifacts.none? { |artifact| artifact.path == DiscoverRdrArtifacts.convention_for(project).directory && artifact.body.nil? }
    end

    def reconcile_project_artifacts
      reconcile_rdr_artifacts
      open_design_pull_requests.find_each do |design_pr|
        reconcile(artifact_for(design_pr), revision: design_pr.head_sha)
      end
    end

    def open_design_pull_requests
      FeatureIntentDesignPr.joins(:feature_intent).includes(feature_intent: { issues: :project }).where(
        feature_intents: { project_id: project.id }, merged_at: nil
      )
    end

    def reconcile(artifact, revision:, coverage_complete: true)
      issues, complete, associated_issues = issue_coverage(artifact)
      PersistDesignArtifactFindings.call(
        project:, revision:, artifacts: [ artifact.merge(associated_issues:) ], issues:,
        coverage_complete: coverage_complete && artifact.fetch(:coverage_complete, true) && complete
      )
    end

    def rdr_artifact(artifact)
      {
        path: artifact.path,
        revision: artifact.revision,
        body: artifact.body,
        status: rdr_status(artifact.body),
        related_issues: explicit_references(artifact.body),
        stored_identities: []
      }
    end

    def rdr_status(body)
      body.to_s[RDR_STATUS_PATTERN, 1]&.strip
    end

    def issue_coverage(artifact)
      references = artifact.fetch(:related_issues)
      projects = projects_for(references)
      associations = Array(artifact[:associated_issues]) + structural_associations(artifact)
      association_projects = associations.filter_map { |association| association[:project] }.uniq
      [
        issue_facts((projects.values + association_projects).uniq),
        references.all? { |reference| projects.key?(repository_for(reference)) },
        associations
      ]
    end

    def structural_associations(artifact)
      exact_backlinks(artifact) + manifest_associations(artifact)
    end

    def exact_backlinks(artifact)
      project.issues.includes(:project).where(
        "issues.body LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(artifact[:path])}%"
      ).filter_map do |issue|
        next if issue.is_pull_request? || !issue.trusted?
        next unless explicit_artifact_backlink?(issue, artifact)

        association_for(issue, "exact artifact backlink")
      end
    end

    def explicit_artifact_backlink?(issue, artifact)
      relationship_text(issue.body).match?(artifact_path_pattern(artifact.fetch(:path)))
    end

    def artifact_path_pattern(path)
      /(?<![\w.\/-])#{Regexp.escape(path)}(?![\w.\/-])/
    end

    def manifest_associations(artifact)
      FeatureIntent.where(project:).includes(issues: :project).filter_map do |feature_intent|
        next unless artifact[:path].in?(feature_intent.design_document_paths)

        feature_intent.issues.filter_map { |issue| association_for(issue, "canonical issue-tree manifest") }
      end.flatten
    end

    def association_for(issue, provenance)
      return unless issue.github_number

      {
        repository: issue.project.full_name,
        number: issue.github_number,
        revision: issue.github_updated_at&.iso8601,
        provenance:, project: issue.project
      }
    end

    def projects_for(references)
      repositories = references.map { |reference| repository_for(reference) }.uniq
      external = repositories - [ project.full_name ]
      projects = Project.where(account_id: project.account_id, owner: external.map { |name| name.split("/").first }, repo: external.map { |name| name.split("/").last })
      projects.to_a.append(project).index_by(&:full_name)
    end

    def issue_facts(projects)
      Issue.joins(:project).includes(:project).where(project_id: projects.map(&:id)).where.not(github_number: nil).filter_map do |issue|
        next if issue.is_pull_request? || !issue.trusted?

        {
          repository: issue.project.full_name, number: issue.github_number, state: issue.github_state,
          title: issue.title, body: issue.body, revision: issue.github_updated_at&.iso8601
        }
      end
    end

    def repository_for(reference)
      reference.split("#", 2).first
    end

    def explicit_references(body)
      relationship_text(body).scan(%r{(?<![\w/-])(?:([\w.-]+/[\w.-]+))?#(\d+)})
        .map { |repository, number| "#{repository || project.full_name}##{number}" }
        .uniq
    end

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

    def identity_for(issue)
      "#{issue.project.full_name}##{issue.github_number}"
    end
  end
end
