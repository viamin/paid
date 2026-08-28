# frozen_string_literal: true

module Inbox
  class Queue
    CLARIFYING_QUESTIONS_KIND = "clarifying_questions"
    PLAN_REVIEW_KIND = "plan_review"
    MERGE_APPROVAL_KIND = "merge_approval"
    KINDS = [
      CLARIFYING_QUESTIONS_KIND,
      PLAN_REVIEW_KIND,
      MERGE_APPROVAL_KIND
    ].freeze

    Entry = Struct.new(
      :id,
      :kind,
      :project,
      :issue,
      :record,
      :waiting_since,
      :questions,
      :tasks,
      :summary_text,
      keyword_init: true
    ) do
      def to_param
        id
      end

      def plan_review?
        kind == PLAN_REVIEW_KIND
      end

      def clarifying_questions?
        kind == CLARIFYING_QUESTIONS_KIND
      end

      def merge_approval?
        kind == MERGE_APPROVAL_KIND
      end

      def title
        issue.title
      end

      def summary
        return questions.first(2).join(" ").truncate(220) if clarifying_questions?
        return summary_text if merge_approval?

        "#{tasks.size} proposed tasks"
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(user:, project: nil, kind: nil)
      @user = user
      @project = project
      @kind = kind.to_s.presence
    end

    # @spec INBOX-FOUNDATION-003
    def call
      entries = []
      entries.concat(clarifying_question_entries) if include_kind?(CLARIFYING_QUESTIONS_KIND)
      entries.concat(plan_review_entries) if include_kind?(PLAN_REVIEW_KIND)
      entries.concat(merge_approval_entries) if include_kind?(MERGE_APPROVAL_KIND)
      sort_entries(entries)
    end

    private

    attr_reader :kind, :project, :user

    def include_kind?(entry_kind)
      kind.blank? || kind == entry_kind
    end

    def sort_entries(entries)
      entries.sort_by do |entry|
        [
          entry.waiting_since.nil? ? 1 : 0,
          entry.waiting_since,
          entry.project.owner,
          entry.project.repo,
          entry.issue.github_number,
          entry.id
        ]
      end
    end

    def clarifying_question_entries
      ordered_clarifying_issues.filter_map do |issue|
        questions = question_summary_for(issue)
        next if questions.empty?

        Entry.new(
          id: "#{CLARIFYING_QUESTIONS_KIND}:#{issue.id}",
          kind: CLARIFYING_QUESTIONS_KIND,
          project: issue.project,
          issue: issue,
          record: issue,
          waiting_since: issue.needs_input_since,
          questions: questions,
          tasks: [],
          summary_text: nil
        )
      end
    end

    # Oldest-waiting-first by `needs_input_since` (NULLS LAST so legacy rows
    # without a timestamp sort to the end of the list rather than pretending
    # to have been waiting forever), then a deterministic tiebreak so the
    # ordering is stable across calls. Includes both issues and pull requests
    # (drops the old `is_pull_request: false` filter) so inbox consumers can
    # grow beyond issue-only needs-input flows without another queue rewrite.
    # @spec INBOX-FOUNDATION-004 @spec INBOX-FOUNDATION-005
    def ordered_clarifying_issues
      @ordered_clarifying_issues ||= begin
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

    def plan_review_entries
      scope = PlanReviewPolicy::Scope.new(user, DecompositionDecision).resolve
      scope = scope.where(project: project) if project

      scope.open_plan_reviews.includes(:project, :issue).map do |review|
        tasks = Array(review.plan_data&.dig("tasks"))

        Entry.new(
          id: "#{PLAN_REVIEW_KIND}:#{review.id}",
          kind: PLAN_REVIEW_KIND,
          project: review.project,
          issue: review.issue,
          record: review,
          waiting_since: review.created_at,
          questions: [],
          tasks: tasks,
          summary_text: nil
        )
      end
    end

    def merge_approval_entries
      merge_approval_issues.filter_map do |issue|
        snapshot = Inbox::MergeApproval.call(issue)
        next unless snapshot

        Entry.new(
          id: "#{MERGE_APPROVAL_KIND}:#{issue.id}",
          kind: MERGE_APPROVAL_KIND,
          project: issue.project,
          issue: issue,
          record: issue,
          waiting_since: snapshot.waiting_since,
          questions: [],
          tasks: [],
          summary_text: snapshot.summary
        )
      end
    end

    def merge_approval_issues
      @merge_approval_issues ||= begin
        ids = scoped_projects.map(&:id)
        return Issue.none if ids.empty?

        Issue
          .includes(:project)
          .where(project_id: ids, is_pull_request: true, github_state: "open", pr_review_phase: "ready")
      end
    end
  end
end
