# frozen_string_literal: true

module Knowledge
  class ContextIntakeController < ApplicationController
    WIZARD_FRAME_ID = "context_intake_wizard"

    before_action :authenticate_user!
    before_action :set_project
    before_action :set_session, only: [ :show, :update, :complete ]
    before_action :require_session!, only: [ :update, :complete ]

    def show
      authorize @project, :show?
      @session ||= latest_session
      return unless @session&.in_progress?
      return render_pending_response if blocking_follow_up_generation_pending? && turbo_frame_request?
      return if blocking_follow_up_generation_pending?

      load_wizard_state(active_question_key: params[:question])
      render_wizard_response if turbo_frame_request?
    end

    def create
      authorize @project, :update?
      abort_if_in_progress!

      @session = ContextIntake::StartSession.call(project: @project, user: current_user)
      redirect_to project_context_intake_path(@project), notice: "Business context questionnaire started."
    end

    def update
      authorize @project, :update?

      save_current_response!
      @session.reload

      if finish_navigation?
        complete_session!
      else
        load_wizard_state(active_question_key: navigation_question_key)
        render_wizard_response
      end
    rescue ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
      @wizard_error = e.message
      target_question_key = error_question_key
      load_wizard_state(
        active_question_key: target_question_key,
        submitted_answer_text: submitted_answer_text_for(target_question_key)
      )
      render_wizard_response(status: :unprocessable_entity)
    end

    def complete
      authorize @project, :update?

      ContextIntake::CompleteSession.call(session: @session)
      redirect_to project_context_intake_path(@project),
        status: :see_other,
        notice: "Business context saved and synthesized into project knowledge."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to project_context_intake_path(@project), alert: e.message
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_session
      @session = @project.context_intake_sessions
                         .where(status: "in_progress")
                         .latest_first
                         .first
    end

    def require_session!
      return if @session

      redirect_to project_context_intake_path(@project), alert: "No active questionnaire session."
    end

    def latest_session
      @project.context_intake_sessions.latest_first.first
    end

    def load_wizard_state(active_question_key: nil, submitted_answer_text: nil)
      state = ContextIntake::WizardFrameState.call(
        session: @session,
        active_question_key: active_question_key,
        submitted_answer_text: submitted_answer_text
      )
      @responses = state[:responses]
      @progress = state[:progress]
      @wizard_state = state[:wizard_state]
      @current_question_index = state[:current_question_index]
      @current_question = state[:current_question]
      @current_response = state[:current_response]
      @current_answer_text = state[:current_answer_text]
      @previous_question = state[:previous_question]
      @next_question = state[:next_question]
    end

    def save_current_response!
      validate_required_answer!

      ContextIntake::SaveResponse.call(
        session: @session,
        question_key: params[:question_key],
        answer_text: normalized_answer_text,
        skipped: skip_navigation?
      )
    end

    def complete_session!
      current_response = @session.context_intake_responses.find_by!(question_key: params[:question_key])
      current_round = ContextIntake::QuestionnaireSchema.question_round_for_response(current_response)
      follow_up_result = ContextIntake::GenerateFollowUpQuestions.call(
        session: @session,
        project: @project,
        current_question_key: params[:question_key]
      )
      agent_generation_enabled = feature_enabled?(:context_intake_agent_questions, project: @project)
      blocking_generation = follow_up_result.next_question_key.blank?
      round_already_attempted = attempted_rounds.include?(current_round)

      enqueued_follow_up_generation = agent_generation_enabled && !round_already_attempted

      if enqueued_follow_up_generation
        mark_follow_up_generation_pending!(current_round:, blocking: blocking_generation)
        ContextIntake::GenerateFollowUpQuestionsJob.perform_later(
          session_id: @session.id,
          project_id: @project.id,
          current_round: current_round,
          blocking: blocking_generation
        )
      else
        mark_round_attempted!(current_round)
      end

      if follow_up_result.next_question_key.present?
        load_wizard_state(active_question_key: follow_up_result.next_question_key)
        return render_wizard_response
      end

      return render_pending_response if enqueued_follow_up_generation

      ContextIntake::CompleteSession.call(session: @session)
      redirect_to project_context_intake_path(@project),
        status: :see_other,
        notice: "Business context saved and synthesized into project knowledge."
    end

    def render_wizard_response(status: :ok)
      if turbo_frame_request?
        render partial: "knowledge/context_intake/wizard_frame",
          locals: wizard_locals, status: status
      else
        render :show, status: status
      end
    end

    def render_pending_response(status: :ok)
      if turbo_frame_request?
        render partial: "knowledge/context_intake/wizard_pending",
          locals: { session: @session }, status: status
      else
        render :show, status: status
      end
    end

    def wizard_locals
      {
        project: @project,
        wizard_state: @wizard_state,
        current_question: @current_question,
        current_answer_text: @current_answer_text,
        current_response: @current_response,
        previous_question: @previous_question,
        next_question: @next_question,
        progress: @progress,
        wizard_error: @wizard_error
      }
    end

    def blocking_follow_up_generation_pending?
      @session.follow_up_generation_pending? && @session.follow_up_generation_blocking?
    end

    def attempted_rounds
      Array(@session.metadata.to_h["follow_up_generation_attempted_rounds"]).map(&:to_i)
    end

    def mark_round_attempted!(round)
      @session.update!(
        metadata: @session.metadata.to_h.merge(
          "follow_up_generation_attempted_rounds" => (attempted_rounds + [ round ]).uniq.sort
        )
      )
    end

    def mark_follow_up_generation_pending!(current_round:, blocking:)
      @session.update!(
        metadata: @session.metadata.to_h.merge(
          "follow_up_generation_attempted_rounds" => (attempted_rounds + [ current_round ]).uniq.sort,
          "follow_up_generation" => {
            "status" => "pending",
            "round" => current_round + 1,
            "blocking" => blocking
          }
        )
      )
    end

    def navigation_action
      params[:navigation_action].presence || "next"
    end

    def skip_navigation?
      navigation_action.start_with?("skip_")
    end

    def normalized_navigation_action
      navigation_action.delete_prefix("skip_")
    end

    def finish_navigation?
      normalized_navigation_action == "finish"
    end

    def navigation_question_key
      wizard_state.navigation_question_key(
        current_question_key: params[:question_key],
        direction: normalized_navigation_action
      )
    end

    def validate_required_answer!
      return unless answer_required_for_navigation?
      return if normalized_answer_text.present?

      raise ActiveRecord::RecordInvalid.new(@session),
        "Please answer this required question before continuing."
    end

    def answer_required_for_navigation?
      current_question_required? && !skip_navigation? && !previous_navigation?
    end

    def current_question_required?
      response = @responses&.[](params[:question_key]) || @session.context_intake_responses.find_by(question_key: params[:question_key])
      response.present? && ContextIntake::QuestionnaireSchema.required_question_for_response?(response)
    end

    def previous_navigation?
      normalized_navigation_action == "previous"
    end

    def error_question_key
      return first_unanswered_required_question_key if finish_navigation?

      params[:question_key]
    end

    def submitted_answer_text_for(target_question_key)
      normalized_answer_text if target_question_key == params[:question_key]
    end

    def first_unanswered_required_question_key
      responses = @session.context_intake_responses.ordered.index_by(&:question_key)

      ContextIntake::WizardState.new(
        responses: responses,
        active_question_key: params[:question_key]
      ).first_unanswered_required_question_key
    end

    def wizard_state
      @wizard_state ||= ContextIntake::WizardState.new(
        responses: @responses || @session.context_intake_responses.index_by(&:question_key)
      )
    end

    def normalized_answer_text
      answer_text = params[:answer_text].to_s
      return if answer_text.strip.empty?

      answer_text
    end

    def abort_if_in_progress!
      existing = @project.context_intake_sessions.in_progress.first
      return unless existing

      redirect_to project_context_intake_path(@project),
        alert: "A questionnaire session is already in progress."
    end
  end
end
