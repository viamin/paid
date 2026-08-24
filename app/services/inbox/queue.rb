# frozen_string_literal: true

module Inbox
  class Queue
    CLARIFYING_QUESTIONS_KIND = "clarifying_questions"
    PLAN_REVIEW_KIND = "plan_review"
    KINDS = [
      CLARIFYING_QUESTIONS_KIND,
      PLAN_REVIEW_KIND
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
      keyword_init: true
    ) do
      def plan_review?
        kind == PLAN_REVIEW_KIND
      end

      def clarifying_questions?
        kind == CLARIFYING_QUESTIONS_KIND
      end

      def title
        issue.title
      end

      def summary
        if clarifying_questions?
          questions.first(2).join(" ").truncate(220)
        else
          "#{tasks.size} proposed tasks"
        end
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

    def call
      entries = []
      entries.concat(clarifying_question_entries) if include_kind?(CLARIFYING_QUESTIONS_KIND)
      entries.concat(plan_review_entries) if include_kind?(PLAN_REVIEW_KIND)
      entries.sort_by { |entry| [ entry.waiting_since, entry.project.full_name, entry.issue.github_number, entry.id ] }
    end

    private

    attr_reader :kind, :project, :user

    def include_kind?(entry_kind)
      kind.blank? || kind == entry_kind
    end

    def clarifying_question_entries
      Dashboard::NeedsInputQueue.call(user: user, project: project).map do |entry|
        Entry.new(
          id: "#{CLARIFYING_QUESTIONS_KIND}:#{entry.issue.id}",
          kind: CLARIFYING_QUESTIONS_KIND,
          project: entry.project,
          issue: entry.issue,
          record: entry.issue,
          waiting_since: entry.issue.updated_at,
          questions: entry.questions,
          tasks: []
        )
      end
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
          tasks: tasks
        )
      end
    end
  end
end
