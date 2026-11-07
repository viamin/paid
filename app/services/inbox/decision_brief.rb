# frozen_string_literal: true

module Inbox
  # A small, deterministic presentation contract for a human Inbox decision.
  # It deliberately consumes the queue's current structured state and never
  # asks a model to infer a recommendation while an operator is waiting.
  # @spec OPERATOR-INBOX-027
  class DecisionBrief
    Result = Data.define(
      :project, :goal, :work_item, :what_changed, :decision, :recommendation,
      :why, :waiting_on, :primary_action, :impact, :evidence_state,
      :uncertainty, :focused_question
    ) do
      def list
        { project:, work_item:, decision:, impact: }
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(entry:)
      @entry = entry
    end

    def call
      Result.new(
        project: entry.project.full_name,
        goal: goal,
        work_item: entry.title,
        what_changed: what_changed,
        decision: decision,
        recommendation: recommendation,
        why: rationale,
        waiting_on: waiting_on,
        primary_action: recommendation || default_action,
        impact: impact,
        evidence_state: evidence_state,
        uncertainty: uncertainty,
        focused_question: focused_question
      )
    end

    private

    attr_reader :entry

    def goal
      return entry.record.brief if entry.record.respond_to?(:brief) && entry.record.brief.present?
      return entry.record.intent if entry.record.respond_to?(:intent) && entry.record.intent.present?

      entry.title
    end

    def decision
      question_payload&.fetch(:question) || entry.summary.presence || entry.title
    end

    def recommendation
      question_payload&.fetch(:recommendation) || guidance_value(:instruction) || notification_recommendation
    end

    def rationale
      question_payload&.fetch(:rationale) || guidance_value(:heading)
    end

    def waiting_on
      return "Paid is waiting for your answer." if question_payload
      return "Paid is waiting for the selected remediation." if entry.tasks.any?

      "Paid is waiting for your decision."
    end

    def what_changed
      return "Paid needs a product decision." if question_payload

      entry.summary
    end

    def impact
      return "Paid is waiting for your answer." if question_payload

      entry.summary.presence || "Paid is waiting for a decision."
    end

    def default_action
      return "Answer the question" if question_payload
      return "Review the available action" if entry.action_url.present?

      "Review this item"
    end

    def evidence_state
      return "stale" if guidance_value(:stale_approval)
      return "current" if recommendation.present?

      "unknown"
    end

    def uncertainty
      return "The recorded approval is stale for the current revision." if evidence_state == "stale"
      return unless evidence_state == "unknown"

      "Paid has no evidence-backed recommendation."
    end

    def focused_question
      return unless evidence_state == "unknown"

      question_payload&.fetch(:question) || "What outcome should Paid pursue next?"
    end

    def question_payload
      return @question_payload if defined?(@question_payload)

      @question_payload = if (entry.clarifying_questions? || entry.manual_review?) && entry.questions.first.present?
        ClarifyingQuestions::QuestionPayload.call(question: entry.questions.first)
      end
    end

    def guidance_value(key)
      guidance = entry.guidance || {}
      guidance[key] || guidance[key.to_s]
    end

    def notification_recommendation
      return unless entry.action_required? && entry.record.respond_to?(:metadata)

      metadata = entry.record.metadata || {}
      metadata["recommended_action"] || metadata[:recommended_action]
    end
  end
end
