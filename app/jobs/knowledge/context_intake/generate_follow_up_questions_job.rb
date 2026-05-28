# frozen_string_literal: true

module Knowledge
  module ContextIntake
    class GenerateFollowUpQuestionsJob < ApplicationJob
      def perform(session_id:, project_id:, current_round:, blocking:)
        session = ContextIntakeSession.find(session_id)
        project = Project.find(project_id)
        return unless session.in_progress?

        generated_questions = GenerateQuestions.call(
          project: project,
          session: session,
          round: current_round + 1,
          auto_approve: true
        )
        created_responses = AppendQuestions.call(
          session: session,
          questions: generated_questions.select(&:approved?).map(&:to_question_hash)
        )

        clear_pending_generation!(session)

        if created_responses.any?
          broadcast_wizard!(session, project, created_responses) if blocking
          return
        end

        return if session.context_intake_responses.unanswered.exists?

        CompleteSession.call(session: session)
        broadcast_summary!(session, project) if blocking
      rescue ActiveRecord::RecordNotFound
        nil
      rescue StandardError => e
        mark_generation_failed!(session, e) if session.present?
        raise
      end

      private

      def clear_pending_generation!(session)
        session.update!(
          metadata: session.metadata.to_h.except("follow_up_generation")
        )
      end

      def mark_generation_failed!(session, error)
        session.update!(
          metadata: session.metadata.to_h.merge(
            "follow_up_generation" => session.follow_up_generation_state.merge(
              "status" => "failed",
              "error_class" => error.class.name,
              "error" => error.message
            )
          )
        )
      rescue StandardError
        nil
      end

      def broadcast_wizard!(session, project, created_responses)
        locals = WizardFrameState.call(
          session: session,
          active_question_key: QuestionnaireSchema.ordered_responses(created_responses).first&.question_key
        )

        Turbo::StreamsChannel.broadcast_replace_to(
          [ session, :context_intake_wizard ],
          target: Knowledge::ContextIntakeController::WIZARD_FRAME_ID,
          partial: "knowledge/context_intake/wizard_frame",
          locals: locals.merge(project: project, wizard_error: nil)
        )
      end

      def broadcast_summary!(session, project)
        Turbo::StreamsChannel.broadcast_replace_to(
          [ session, :context_intake_wizard ],
          target: Knowledge::ContextIntakeController::WIZARD_FRAME_ID,
          partial: "knowledge/context_intake/summary_frame",
          locals: { session: session, project: project }
        )
      end
    end
  end
end
