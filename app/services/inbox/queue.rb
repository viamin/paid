# frozen_string_literal: true

module Inbox
  # Returns typed entries for everything in the user's auto-pick scope that
  # is currently waiting on human input. Today only one kind exists
  # (:clarifying_questions); the entry shape is fixed so future kinds
  # (plan review, PR owner approval, paused-run decisions) slot in without UI
  # churn.
  #
  # Generalizes Dashboard::NeedsInputQueue (which now delegates here for the
  # issues-only subset it renders). Key differences:
  #   * Includes PRs (drops the `is_pull_request: false` filter)
  #   * Orders oldest-waiting-first by `needs_input_since ASC NULLS LAST`
  #     with a stable tiebreak (owner, repo, github_number, id)
  #
  # Visibility/scoping semantics are identical to Dashboard::NeedsInputQueue:
  # auto-pick projects only, gated by Issues::AutoPickProjectGate, restricted
  # to projects the user owns (plus orphaned-project visibility).
  class Queue
    Entry = Struct.new(:kind, :project, :issue, :questions, :waiting_since, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(user:, project: nil)
      @user = user
      @project = project
    end

    # @spec INBOX-FOUNDATION-003
    def call
      @call ||= ordered_issues.filter_map do |issue|
        questions = question_summary_for(issue)
        next if questions.empty?

        Entry.new(
          kind: :clarifying_questions,
          project: issue.project,
          issue: issue,
          questions: questions,
          waiting_since: issue.needs_input_since
        )
      end
    end

    private

    attr_reader :user, :project

    # Oldest-waiting-first by `needs_input_since` (NULLS LAST so legacy rows
    # without a timestamp sort to the end of the list rather than pretending
    # to have been waiting forever), then a deterministic tiebreak so the
    # ordering is stable across calls. Index
    # `index_issues_needs_input_since_active` (partial on paid_state =
    # 'needs_input') supports the leading column.
    # Includes both issues and pull requests (drops the `is_pull_request:
    # false` filter); today's needs_input flow only stamps issues, but the
    # inbox page is structurally ready for future PR-blocking kinds.
    # @spec INBOX-FOUNDATION-004 @spec INBOX-FOUNDATION-005
    def ordered_issues
      @ordered_issues ||= begin
        ids = scoped_projects.map(&:id)
        return Issue.none if ids.empty?

        Issue
          .joins(:project)
          .includes(:project)
          .where(project_id: ids, paid_state: "needs_input", github_state: "open")
          .order(Arel.sql("issues.needs_input_since ASC NULLS LAST"))
          .order("projects.owner ASC", "projects.repo ASC", "issues.github_number ASC", "issues.id ASC")
      end
    end

    # @spec INBOX-FOUNDATION-006
    def scoped_projects
      projects = auto_pick_projects
      return projects unless project

      projects.select { |candidate| candidate.id == project.id }
    end

    # @spec INBOX-FOUNDATION-006
    def auto_pick_projects
      @auto_pick_projects ||= Project
        .includes(account: :tenant_setting, created_by: :user_setting)
        .where(
          account_id: user.account_id,
          created_by_id: visible_owner_ids,
          auto_pick_enabled: true,
          active: true
        )
        .select { |candidate| Issues::AutoPickProjectGate.call(candidate) }
    end

    def visible_owner_ids
      owner_ids = [ user.id ]
      owner_ids << nil if AgentRun.orphaned_project_owner?(user)
      owner_ids
    end

    # Questionless rows are invalid and repaired during sync, so keep them out
    # of every queue consumer until reconciliation clears the stale state.
    def question_summary_for(issue)
      questions = ClarifyingQuestions::Parse.call(comment_body: issue.body)
      return questions if questions.any?

      # create_feature runs persist their clarifying questions locally when
      # the needs-input comment is posted, so the dashboard renders without a
      # per-issue GitHub API round-trip (RDR-053).
      Array(issue.needs_input_questions)
    end
  end
end
