# frozen_string_literal: true

module FeatureIntents
  # Reconciles one known design pull request using the synchronized local
  # issue mirror. GitHub synchronization is the authority for both inputs;
  # this job never makes write calls to GitHub.
  # @spec DESIGN-RECONCILIATION-001
  class ReconcileDesignArtifactsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

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
      FeatureIntentDesignPr.joins(:feature_intent).includes(feature_intent: :issues).find_by(
        feature_intents: { project_id: project.id }, pull_request_number:
      )
    end

    def artifact_for(design_pr)
      issue = project_issue(design_pr.pull_request_number)
      {
        path: "pull/#{design_pr.pull_request_number}",
        status: design_pr.draft? ? "draft" : nil,
        related_issues: explicit_references(issue&.body),
        stored_identities: design_pr.feature_intent.issues.map { |linked| identity_for(linked) }
      }
    end

    def project_issue(number)
      @project_issue ||= {}
      @project_issue[number] ||= project.issues.find_by(github_number: number)
    end

    def reconcile_rdr_artifacts
      DiscoverRdrArtifacts.call(project:).each do |artifact|
        reconcile(rdr_artifact(artifact), revision: artifact.revision, coverage_complete: artifact.body.present?)
      end
    end

    def reconcile_project_artifacts
      reconcile_rdr_artifacts
      open_design_pull_requests.find_each do |design_pr|
        reconcile(artifact_for(design_pr), revision: design_pr.head_sha)
      end
    end

    def open_design_pull_requests
      FeatureIntentDesignPr.joins(:feature_intent).includes(feature_intent: :issues).where(
        feature_intents: { project_id: project.id }, merged_at: nil
      )
    end

    def reconcile(artifact, revision:, coverage_complete: true)
      issues, complete = issue_coverage(artifact)
      PersistDesignArtifactFindings.call(
        project:, revision:, artifacts: [ artifact ], issues:, coverage_complete: coverage_complete && complete
      )
    end

    def rdr_artifact(artifact)
      { path: artifact.path, related_issues: explicit_references(artifact.body), stored_identities: [] }
    end

    def issue_coverage(artifact)
      references = artifact.fetch(:related_issues)
      projects = projects_for(references)
      [ issue_facts(projects.values), references.all? { |reference| projects.key?(repository_for(reference)) } ]
    end

    def projects_for(references)
      repositories = references.map { |reference| repository_for(reference) }.uniq
      external = repositories - [ project.full_name ]
      projects = Project.where(account_id: project.account_id, owner: external.map { |name| name.split("/").first }, repo: external.map { |name| name.split("/").last })
      projects.to_a.append(project).index_by(&:full_name)
    end

    def issue_facts(projects)
      Issue.joins(:project).where(project_id: projects.map(&:id)).where.not(github_number: nil)
        .pluck("projects.owner", "projects.repo", "issues.github_number")
        .map { |owner, repo, number| { repository: "#{owner}/#{repo}", number: } }
    end

    def repository_for(reference)
      reference.split("#", 2).first
    end

    def explicit_references(body)
      body.to_s.scan(%r{(?<![\w/-])(?:([\w.-]+/[\w.-]+))?#(\d+)})
        .map { |repository, number| "#{repository || project.full_name}##{number}" }
        .uniq
    end

    def identity_for(issue)
      "#{issue.project.full_name}##{issue.github_number}"
    end
  end
end
