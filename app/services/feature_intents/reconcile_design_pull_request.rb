# frozen_string_literal: true

module FeatureIntents
  # Projects provider PR facts onto the linked design artifact. A completed,
  # verified human direct merge records approval through MarkApproved; bot or
  # unverifiable merges still require an existing human approval.
  # @spec FEATURE-APPROVAL-012 @spec FEATURE-APPROVAL-016
  class ReconcileDesignPullRequest
    def self.call(...)
      new(...).call
    end

    def initialize(project:, github_issue:, github_pull_request: nil, authenticated_login_resolver: nil)
      @project = project
      @github_issue = github_issue
      @github_pull_request = github_pull_request
      @authenticated_login_resolver = authenticated_login_resolver || ->(token) { token.client.authenticated_login }
    end

    def call
      return unless design_pr

      update_head
      return cancel_hold if closed_unmerged?
      return unless merged?

      design_pr.update!(merged_at: merged_at || Time.current)
      approve_direct_merge
      Release.call(feature_intent: design_pr.feature_intent, revision: merge_revision)
    end

    private

    attr_reader :project, :github_issue, :github_pull_request, :authenticated_login_resolver

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

    # A direct merge can approve only the complete design. Earlier merged
    # artifacts remain held until the final required artifact is merged.
    def approve_direct_merge
      return unless required_design_prs.all?(&:merged?)
      return if feature_intent.approved_waiting_for_merge?

      MarkApproved.call(feature_intent:, actor: verified_merger, source: "github_direct_merge") if verified_merger
    rescue MarkApproved::NotAuthorizedError, MarkApproved::NotReadyError, FeatureIntent::InvalidTransitionError => e
      log_direct_merge_rejection(e)
    end

    def feature_intent = design_pr.feature_intent

    def required_design_prs
      feature_intent.feature_intent_design_prs.select(&:required?)
    end

    # A GitHub login is not a Paid identity. Resolve it by asking each active
    # account credential for its provider-authenticated identity, then let
    # MarkApproved apply Paid's membership policy to its owning user.
    def verified_merger
      return unless human_merger?

      active_account_tokens.find { |token| token_matches_merger?(token) }&.created_by
    end

    def active_account_tokens
      project.account.github_tokens.active.includes(:created_by)
    end

    def token_matches_merger?(token)
      token.created_by && authenticated_login_resolver.call(token)&.casecmp?(merged_by_login)
    end

    def human_merger?
      login = merged_by_login.to_s
      login.present? && !merged_by_type.to_s.casecmp?("bot") && !login.end_with?("[bot]")
    end

    def merged_by_login
      merged_by = pull_request_value(:merged_by)
      merged_by.respond_to?(:login) ? merged_by.login : merged_by&.fetch(:login, nil)
    end

    def merged_by_type
      merged_by = pull_request_value(:merged_by)
      merged_by.respond_to?(:type) ? merged_by.type : merged_by&.fetch(:type, nil)
    end

    def log_direct_merge_rejection(error)
      Rails.logger.info(
        message: "feature_intents.direct_merge_approval_rejected",
        feature_intent_id: feature_intent.id,
        project_id: project.id,
        error_class: error.class.name
      )
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
