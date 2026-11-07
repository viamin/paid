# frozen_string_literal: true

module Inbox
  # A small, deterministic presentation contract shared by every Inbox surface.
  # It only reads the queue entry and its persisted guidance; it never asks an
  # LLM to reinterpret an operator decision while rendering.
  # @spec OPERATOR-INBOX-027
  class DecisionBrief
    Result = Data.define(:goal, :changed, :decision, :recommendation,
      :recommendation_reason, :waiting_work, :primary_action, :next_state, :unknown) do
      def to_h
        members.index_with { |member| public_send(member) }.compact
      end

      def list_summary
        [ decision, changed ].compact.join(" — ")
      end
    end

    ACTIONS = {
      Queue::CLARIFYING_QUESTIONS_KIND => [ "Answer the question", "Paid can continue with your answer." ],
      Queue::ACTION_REQUIRED_KIND => [ "Complete remediation", "Blocked work can resume after the remediation is recorded." ],
      Queue::MANUAL_REVIEW_KIND => [ "Review recovery", "Paid will only resume through the selected recovery path." ],
      Queue::PARTIAL_CLOSEOUT_KIND => [ "Resolve remaining work", "The issue can be reassessed after the remaining work is recorded." ],
      Queue::PLAN_REVIEW_KIND => [ "Review the plan", "Planning continues with the recorded decision." ]
    }.freeze

    def self.call(entry = nil, **kwargs)
      new(entry || kwargs.fetch(:entry)).call
    end

    def initialize(entry)
      @entry = entry
    end

    def call
      Result.new(goal:, changed:, decision:, recommendation:, recommendation_reason:, waiting_work:,
        primary_action: action.first, next_state: action.last, unknown:)
    end

    private

    attr_reader :entry

    def goal
      entry.title.presence || "Current project work"
    end

    def changed
      entry.summary.presence || "This work is waiting for a human decision."
    end

    def decision
      case entry.kind
      when Queue::CLARIFYING_QUESTIONS_KIND then question_payload[:question] || "Answer the product question."
      when Queue::MANUAL_REVIEW_KIND then "Choose whether and how Paid should resume."
      when Queue::PARTIAL_CLOSEOUT_KIND then "Choose how to finish the remaining acceptance criteria."
      when Queue::ACTION_REQUIRED_KIND then "Complete the required remediation."
      when Queue::PLAN_REVIEW_KIND then "Approve, reject, or revise the proposed plan."
      else "Review and take the requested action."
      end
    end

    def recommendation
      case entry.kind
      when Queue::CLARIFYING_QUESTIONS_KIND then question_payload[:recommendation]
      when Queue::ACTION_REQUIRED_KIND, Queue::PARTIAL_CLOSEOUT_KIND then entry.tasks.first.to_s.presence
      when Queue::MERGE_APPROVAL_KIND then entry.guidance&.fetch(:instruction, nil)
      end
    end

    def recommendation_reason
      return question_payload[:rationale] if entry.clarifying_questions?
      return "This is the first recorded remediation step." if entry.action_required? && recommendation
      return "This is the first unresolved prerequisite." if entry.partial_closeout? && recommendation
      "This guidance comes from the current merge assessment." if entry.merge_approval? && recommendation
    end

    def waiting_work
      return "Work is waiting for your answer." if entry.clarifying_questions?
      return "Work is waiting for the required remediation." if entry.action_required?
      return "Automation is waiting for an authorized recovery decision." if entry.manual_review?
      return "Remaining acceptance work is waiting for an owner." if entry.partial_closeout?

      "Work is waiting for this decision."
    end

    def unknown
      return unless recommendation.blank?

      entry.clarifying_questions? ? decision : "What is the next safe action for this work?"
    end

    def action
      ACTIONS.fetch(entry.kind, [ "Review this item", "Paid will recheck the item after the action is recorded." ])
    end

    def question_payload
      @question_payload ||= ClarifyingQuestions::QuestionPayload.call(question: entry.questions.first)
    end
  end
end
