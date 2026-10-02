# frozen_string_literal: true

module FeatureIntents
  # Projects provider PR facts onto the linked design artifact. Approval is
  # deliberately not inferred here: a bot merge can update merge state, but
  # Release still requires the previously recorded human approval.
  # @spec FEATURE-APPROVAL-016
  class ReconcileDesignPullRequest
    def self.call(...)
      new(...).call
    end

    def initialize(project:, github_issue:, github_pull_request: nil)
      @project = project
      @github_issue = github_issue
      @github_pull_request = github_pull_request
    end

    def call
      return unless design_pr

      update_head
      return cancel_hold if closed_unmerged?
      return unless merged?

      design_pr.update!(merged_at: merged_at || Time.current)
      Release.call(feature_intent: design_pr.feature_intent, revision: merge_revision)
    end

    private

    attr_reader :project, :github_issue, :github_pull_request

    def design_pr
      @design_pr ||= FeatureIntentDesignPr.joins(:feature_intent).find_by(
        feature_intents: { project_id: project.id }, pull_request_number: github_issue.number
      )
    end

    def update_head
      return if head_sha.blank? || design_pr.head_sha == head_sha

      design_pr.update!(head_sha: head_sha)
    end

    def cancel_hold
      feature = design_pr.feature_intent
      return unless feature.status.in?(FeatureIntent::APPROVABLE_STATUSES + [ "approved_waiting_for_merge" ])

      feature.update!(status: "design_open", approved_by: nil, approved_at: nil, approved_pr_heads: {})
    end

    def merged? = merged_at.present?

    def closed_unmerged? = github_issue.state == "closed" && !merged?

    def merged_at
      pull_request_value(:merged_at)
    end

    def merge_revision
      pull_request_value(:merge_commit_sha).presence || github_issue.respond_to?(:merge_commit_sha) && github_issue.merge_commit_sha
    end

    def head_sha
      head = pull_request_value(:head)
      head.respond_to?(:sha) ? head.sha : head&.fetch(:sha, nil)
    end

    def pull_request_value(key)
      pull_request = github_pull_request || (github_issue.pull_request if github_issue.respond_to?(:pull_request))
      pull_request.respond_to?(key) ? pull_request.public_send(key) : pull_request&.fetch(key, nil)
    end
  end
end
