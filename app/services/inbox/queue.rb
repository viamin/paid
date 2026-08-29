# frozen_string_literal: true

module Inbox
  class Queue
    CLARIFYING_QUESTIONS_KIND = "clarifying_questions"
    PLAN_REVIEW_KIND = "plan_review"
    MERGE_APPROVAL_KIND = "merge_approval"
    ACTION_REQUIRED_KIND = "action_required"
    KINDS = [
      CLARIFYING_QUESTIONS_KIND,
      PLAN_REVIEW_KIND,
      MERGE_APPROVAL_KIND,
      ACTION_REQUIRED_KIND
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
      :title_text,
      :action_url,
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

      def action_required?
        kind == ACTION_REQUIRED_KIND
      end

      def title
        title_text.presence || issue&.title || record.try(:title)
      end

      def summary
        return questions.first(2).join(" ").truncate(220) if clarifying_questions?
        return summary_text if merge_approval? || action_required?

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
      entries.concat(action_required_entries) if include_kind?(ACTION_REQUIRED_KIND)
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
          entry.project&.owner.to_s,
          entry.project&.repo.to_s,
          entry.issue&.github_number || 0,
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
          summary_text: nil,
          title_text: nil,
          action_url: nil
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
          summary_text: nil,
          title_text: nil,
          action_url: nil
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
          summary_text: snapshot.summary,
          title_text: nil,
          action_url: nil
        )
      end
    end

    def action_required_entries
      visible_blocking_notifications.filter_map do |notification|
        project, issue = notification_context(notification)
        next unless project
        next if project_filter_excludes?(project)

        Entry.new(
          id: "#{ACTION_REQUIRED_KIND}:#{notification.id}",
          kind: ACTION_REQUIRED_KIND,
          project: project,
          issue: issue,
          record: notification,
          waiting_since: notification.created_at,
          questions: [],
          tasks: remediation_steps_for(notification),
          summary_text: notification.metadata["recommended_action"],
          title_text: notification.title,
          action_url: notification.action_url
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

    def visible_blocking_notifications
      @visible_blocking_notifications ||= begin
        notifications = NotificationPolicy::Scope.new(user, Notification).resolve
          .active
          .blocking
          .includes(:subject)
          .recent
          .to_a

        preload_notification_subjects(notifications)
        notifications
      end
    end

    # notification_context dereferences subject.project for every entry, and
    # for AgentRun subjects also calls source_pull_request_record. Batch both
    # up front so an inbox page with N blocking notifications doesn't issue
    # O(N) extra project/PR lookups.
    def preload_notification_subjects(notifications)
      Notification.preload_resolved_projects(notifications)

      subjects = notifications.filter_map(&:subject)
      agent_runs = subjects.select { |subject| subject.is_a?(AgentRun) }
      runners = subjects.select { |subject| subject.is_a?(Runner) }

      ActiveRecord::Associations::Preloader.new(records: agent_runs, associations: :issue).call
      ActiveRecord::Associations::Preloader.new(records: runners, associations: :user).call
      AgentRun.preload_source_pull_requests(agent_runs)
    end

    def remediation_steps_for(notification)
      steps = Array(notification.metadata["remediation_steps"])
      return steps if steps.any?

      Array(notification.metadata["recommended_action"])
    end

    def notification_context(notification)
      issue = case notification.subject
      when Issue then notification.subject
      when AgentRun then notification.subject.source_pull_request_record || notification.subject.issue
      end

      project = case notification.subject
      when Runner then runner_project(notification.subject)
      else notification.resolved_project
      end

      [ project, issue ]
    end

    def project_filter_excludes?(candidate_project)
      project.present? && candidate_project.id != project.id
    end

    def runner_project(runner)
      runner_projects_by_user_id[runner.user_id]&.first
    end

    def runner_projects_by_user_id
      @runner_projects_by_user_id ||= scoped_projects.group_by(&:created_by_id)
    end
  end
end
