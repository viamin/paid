# frozen_string_literal: true

module Inbox
  # Cheap, approximate count of the current user's inbox entries for the nav
  # badge. Unlike Inbox::Queue, this never loads issue bodies or parses
  # clarifying questions per candidate — it counts needs_input rows on gated
  # projects plus open plan reviews, cached for a short TTL per user.
  # Questionless needs_input rows are invalid and repaired during sync, so
  # counting them here (without a question-presence check) is a deliberate,
  # bounded approximation rather than a rendering bug.
  class Count
    CACHE_TTL = 90.seconds
    DISPLAY_CAP = 99

    def self.call(...)
      new(...).call
    end

    def initialize(user:)
      @user = user
    end

    # @spec OPERATOR-INBOX-010
    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { compute_count }
    end

    private

    attr_reader :user

    def compute_count
      needs_input_count + open_plan_review_count + merge_approval_count
    end

    def needs_input_count
      project_ids = gated_project_ids
      return 0 if project_ids.empty?

      Issue.where(project_id: project_ids, paid_state: "needs_input", github_state: "open").count
    end

    def open_plan_review_count
      PlanReviewPolicy::Scope.new(user, DecompositionDecision).resolve.open_plan_reviews.count
    end

    def merge_approval_count
      project_ids = gated_project_ids
      return 0 if project_ids.empty?

      Issue
        .includes(:project)
        .where(project_id: project_ids, is_pull_request: true, github_state: "open", pr_review_phase: "ready")
        .count { |issue| Inbox::MergeApproval.call(issue).present? }
    end

    def gated_project_ids
      Project
        .includes(account: :tenant_setting, created_by: :user_setting)
        .where(
          account_id: user.account_id,
          created_by_id: visible_owner_ids,
          auto_pick_enabled: true,
          active: true
        )
        .select { |candidate| Issues::AutoPickProjectGate.call(candidate) }
        .map(&:id)
    end

    def visible_owner_ids
      owner_ids = [ user.id ]
      owner_ids << nil if AgentRun.orphaned_project_owner?(user)
      owner_ids
    end

    def cache_key
      "inbox/count/#{user.account_id}/#{user.id}/#{Dashboard::CacheVersion.current(user.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)}"
    end
  end
end
