# frozen_string_literal: true

require "digest"

module ClarifyingQuestions
  # Records a confirmed human answer as draft exploration progress. It never
  # posts to GitHub or changes the issue's needs-input state; that remains the
  # explicit final-submission action.
  # @spec QUESTION-EXPLORATION-002 @spec QUESTION-EXPLORATION-013
  class SaveProgress
    def self.question_digest(questions)
      Digest::SHA256.hexdigest(AnswerPairs.normalize_questions(questions).join("\n"))
    end

    def self.call(...)
      new(...).call
    end

    def initialize(chat_session:, position:, answer:, actor:, evidence_context: nil, design_claim: nil)
      @chat_session = chat_session
      @position = position.to_i
      @answer = answer.to_s.strip
      @actor = actor
      @evidence_context = evidence_context.to_s.strip.truncate(ClarifyingQuestionProgress::EVIDENCE_CONTEXT_MAX_CHARS, omission: "…").presence
      @design_claim = design_claim.to_s.strip.presence
    end

    def call
      validate!
      ensure_question_set!
      persist_answer!
    end

    private

    attr_reader :answer, :actor, :chat_session, :design_claim, :evidence_context, :position

    def validate!
      raise ArgumentError, "This chat is not linked to clarifying questions" unless issue
      raise ArgumentError, "Answer cannot be blank" if answer.blank?
    end

    def ensure_question_set!
      raise ArgumentError, "No pending clarifying questions found" if questions.empty?
      raise ArgumentError, "Question position is out of range" unless questions.fetch(position - 1, nil)

      questions.each_with_index { |question, index| progress_for(question:, position: index + 1) }
    end

    def persist_answer!
      progress_for(question: question, position:).tap do |progress|
        progress.update!(
          answer:,
          evidence_context: evidence_context || progress.evidence_context,
          design_claim: design_claim || progress.design_claim,
          answered_by: actor,
          answered_at: Time.current
        )
      end
    end

    def progress_for(question:, position:)
      progress = ClarifyingQuestionProgress.find_or_initialize_by(issue:, question_digest:, position:)
      return progress if progress.persisted?

      progress.assign_attributes(account: issue.project.account, project: issue.project, chat_session:, question:)
      progress.save!
      progress
    rescue ActiveRecord::RecordNotUnique
      ClarifyingQuestionProgress.find_by!(issue:, question_digest:, position:)
    end

    # @spec QUESTION-EXPLORATION-018 — resolves the focused issue of a feature
    # conversation, or the linked standalone issue.
    def issue
      chat_session.exploration_issue
    end

    def questions
      @questions ||= session_questions.presence || persisted_questions.presence || load_questions
    end

    def session_questions
      Array(chat_session.metadata&.fetch("clarifying_questions", nil))
    end

    def persisted_questions
      Array(issue.needs_input_questions)
    end

    def load_questions
      ClarifyingQuestions::Load.call(project: issue.project, issue: issue)
    end

    def question
      questions.fetch(position - 1)
    end

    def question_digest
      @question_digest ||= self.class.question_digest(questions)
    end
  end
end
