# frozen_string_literal: true

module Knowledge
  module ContextIntake
    class FinishRound
      Result = Struct.new(
        :next_question_key,
        :pending_generation,
        :completed,
        keyword_init: true
      ) do
        def pending_generation?
          pending_generation
        end

        def completed?
          completed
        end
      end

      attr_reader :session, :project, :current_question_key, :agent_generation_enabled

      def initialize(session:, project:, current_question_key:, agent_generation_enabled:)
        @session = session
        @project = project
        @current_question_key = current_question_key
        @agent_generation_enabled = agent_generation_enabled
      end

      def self.call(...)
        new(...).call
      end

      def call
        current_round = QuestionnaireSchema.question_round_for_response(current_response)
        follow_up_result = GenerateFollowUpQuestions.call(
          session: session,
          project: project,
          current_question_key: current_question_key
        )
        enqueued_follow_up_generation = enqueue_follow_up_generation_if_needed!(
          current_round: current_round,
          blocking: follow_up_result.next_question_key.blank?
        )

        return Result.new(next_question_key: follow_up_result.next_question_key, pending_generation: false, completed: false) if follow_up_result.next_question_key.present?
        return Result.new(next_question_key: nil, pending_generation: true, completed: false) if enqueued_follow_up_generation

        CompleteSession.call(session: session)
        Result.new(next_question_key: nil, pending_generation: false, completed: true)
      end

      private

      def current_response
        @current_response ||= session.context_intake_responses.find_by!(question_key: current_question_key)
      end

      def enqueue_follow_up_generation_if_needed!(current_round:, blocking:)
        if agent_generation_enabled && !attempted_rounds.include?(current_round)
          mark_follow_up_generation_pending!(current_round:, blocking:)
          GenerateFollowUpQuestionsJob.perform_later(
            session_id: session.id,
            project_id: project.id,
            current_round: current_round,
            blocking: blocking
          )
          true
        else
          mark_round_attempted!(current_round)
          false
        end
      end

      def attempted_rounds
        Array(session.metadata.to_h["follow_up_generation_attempted_rounds"]).map(&:to_i)
      end

      def mark_round_attempted!(round)
        session.update!(
          metadata: session.metadata.to_h.merge(
            "follow_up_generation_attempted_rounds" => (attempted_rounds + [ round ]).uniq.sort
          )
        )
      end

      def mark_follow_up_generation_pending!(current_round:, blocking:)
        session.update!(
          metadata: session.metadata.to_h.merge(
            "follow_up_generation_attempted_rounds" => (attempted_rounds + [ current_round ]).uniq.sort,
            "follow_up_generation" => {
              "status" => "pending",
              "round" => current_round + 1,
              "blocking" => blocking
            }
          )
        )
      end
    end
  end
end
