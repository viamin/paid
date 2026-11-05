# frozen_string_literal: true

module Inbox
  # A small, deterministic presentation contract shared by every Inbox surface.
  # It intentionally projects recorded queue state; it never asks an LLM to
  # infer intent or a recommendation while an operator is waiting.
  # @spec OPERATOR-INBOX-026
  class DecisionBrief
    Brief = Data.define(:project, :work_item, :goal, :changed, :decision,
      :recommendation, :why, :waiting_on, :primary_action, :alternatives,
      :evidence_status, :unknown, :focused_question)

    DECISIONS = {
      Queue::CLARIFYING_QUESTIONS_KIND => "Answer one product question.",
      Queue::PLAN_REVIEW_KIND => "Review the proposed plan.",
      Queue::ACTION_REQUIRED_KIND => "Complete the required remediation.",
      Queue::MANUAL_REVIEW_KIND => "Review the held work and choose its recovery.",
      Queue::FEATURE_DECISION_KIND => "Make the feature decision.",
      Queue::PARTIAL_CLOSEOUT_KIND => "Decide how to finish the remaining work."
    }.freeze

    def self.call(...) = new(...).call

    def initialize(entry:, detailed: false)
      @entry = entry
      @detailed = detailed
    end

    def call
      Brief.new(project: entry.project.full_name, work_item: work_item, goal: work_item,
        changed: entry.summary, decision: decision, recommendation:, why: entry.summary,
        waiting_on: waiting_on, primary_action: primary_action, alternatives: [],
        evidence_status:, unknown:, focused_question:)
    end

    private

    attr_reader :entry

    def work_item = entry.issue&.title.presence || entry.title.presence || "Untitled work item"

    def decision = DECISIONS.fetch(entry.kind, "Review the current work and choose the next action.")

    def recommendation
      return partial_closeout_recommendation if entry.partial_closeout?
      return if entry.clarifying_questions?

      entry.tasks.first.presence || "Review the recorded state and complete the named action."
    end

    def partial_closeout_recommendation
      return "Request a fresh audit before deciding what is complete." if partial_closeout_assessment&.stale?

      "Review the current acceptance assessment, then continue the remaining work or request a fresh audit."
    end

    def primary_action
      return "Answer the question below." if entry.clarifying_questions?

      recommendation
    end

    def waiting_on
      Array(entry.tasks).filter_map { |task| task.to_s.presence }.first(3)
    end

    def evidence_status
      return "stale" if entry.partial_closeout? && partial_closeout_assessment&.stale?

      "current"
    end

    def unknown
      "Paid cannot recommend an answer from the recorded evidence." if entry.clarifying_questions?
    end

    def focused_question
      entry.questions.first if entry.clarifying_questions?
    end

    def partial_closeout_assessment
      return unless @detailed && entry.issue

      @partial_closeout_assessment ||= PartialCloseouts::Assessment.call(entry.issue)
    end
  end
end
