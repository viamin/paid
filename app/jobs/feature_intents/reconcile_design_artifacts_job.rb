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

    def perform(project_id, pull_request_number)
      @project = Project.find(project_id)
      design_pr = design_pull_request(pull_request_number)
      return unless design_pr

      PersistDesignArtifactFindings.call(
        project:, revision: design_pr.head_sha, artifacts: [ artifact_for(design_pr) ],
        issues: issue_facts, coverage_complete: true
      )
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
        status: issue&.labels&.include?("draft") ? "draft" : nil,
        related_issues: explicit_references(issue&.body),
        stored_identities: design_pr.feature_intent.issues.map { |linked| identity_for(linked) }
      }
    end

    def project_issue(number)
      @project_issue ||= {}
      @project_issue[number] ||= project.issues.find_by(github_number: number)
    end

    def issue_facts
      project.issues.where.not(github_number: nil).pluck(:github_number).map do |number|
        { repository: project.full_name, number: }
      end
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
