# frozen_string_literal: true

module Dashboard
  class NeedsInputQueue
    Entry = Struct.new(:project, :issue, :questions, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def self.next_issue(...)
      new(...).next_issue
    end

    def initialize(user:, project: nil, after_issue: nil)
      @user = user
      @project = project
      @after_issue = after_issue
    end

    def call
      queued_entries
    end

    def next_issue
      queue = queued_entries.map(&:issue)
      return queue.first if after_issue.blank?

      current_index = queue.index { |issue| issue.id == after_issue.id }
      return if current_index.nil?

      queue[(current_index + 1)..]&.first
    end

    private

    attr_reader :after_issue, :project, :user

    # Shared by +call+ (dashboard render) and +next_issue+ (queue navigation).
    # Questionless rows are invalid and repaired during sync, but keep them
    # visible defensively if a stale row reaches the dashboard first.
    def queued_entries
      @queued_entries ||= ordered_issues.filter_map do |issue|
        questions = question_summary_for(issue)
        Entry.new(
          project: issue.project,
          issue: issue,
          questions: questions
        )
      end
    end

    def ordered_issues
      @ordered_issues ||= begin
        ids = scoped_projects.map(&:id)
        return Issue.none if ids.empty?

        Issue.joins(:project)
          .includes(:project)
          .where(
            project_id: ids,
            paid_state: "needs_input",
            github_state: "open",
            is_pull_request: false
          )
          .order("projects.owner ASC", "projects.repo ASC", "issues.github_number ASC", "issues.id ASC")
      end
    end

    def scoped_projects
      projects = auto_pick_projects
      return projects unless project

      projects.select { |candidate| candidate.id == project.id }
    end

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
