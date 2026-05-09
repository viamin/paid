# frozen_string_literal: true

module Knowledge
  class ContextIntakeController < ApplicationController
    before_action :authenticate_user!
    before_action :set_project
    before_action :set_session, only: [ :show, :update, :complete ]
    before_action :require_session!, only: [ :update, :complete ]

    def show
      authorize @project, :show?
      @session ||= latest_session
      load_wizard_state(active_section_key: params[:section]) if @session&.in_progress?
    end

    def create
      authorize @project, :update?
      abort_if_in_progress!

      @session = ContextIntake::StartSession.call(project: @project, user: current_user)
      redirect_to project_context_intake_path(@project), notice: "Business context questionnaire started."
    end

    def update
      authorize @project, :update?

      question_key = params[:question_key]
      skipped = params[:skipped] == "true"
      answer_text = params[:answer_text]

      ContextIntake::SaveResponse.call(
        session: @session,
        question_key: question_key,
        answer_text: answer_text,
        skipped: skipped
      )

      load_wizard_state(active_section_key: preferred_section_after_update(question_key))
      render :show
    rescue ArgumentError => e
      redirect_to project_context_intake_path(@project), alert: e.message
    end

    def complete
      authorize @project, :update?

      ContextIntake::CompleteSession.call(session: @session)
      redirect_to project_context_intake_path(@project),
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

    def load_wizard_state(active_section_key: nil)
      @sections = ContextIntake::QuestionnaireSchema.sections
      @responses = @session.context_intake_responses.ordered.index_by(&:question_key)
      @progress = @session.progress
      @active_section_key = resolve_active_section_key(active_section_key)
    end

    def resolve_active_section_key(active_section_key)
      valid_section_keys = @sections.map { |section| section[:key] }
      requested_section = active_section_key.presence_in(valid_section_keys)

      requested_section || next_incomplete_section_key || @sections.first&.fetch(:key, nil)
    end

    def next_incomplete_section_key
      @sections.find do |section|
        section[:questions].any? { |question| !@responses[question[:key]]&.answered? }
      end&.fetch(:key, nil)
    end

    def preferred_section_after_update(question_key)
      section_key = ContextIntake::QuestionnaireSchema.find_question(question_key)&.dig(:section, :key)
      return unless section_key

      responses = @session.context_intake_responses.index_by(&:question_key)

      return section_key if section_has_unanswered_questions?(section_key, responses)

      next_incomplete_section_key_for_session(responses) || section_key
    end

    def section_has_unanswered_questions?(section_key, responses)
      section = ContextIntake::QuestionnaireSchema.sections.find { |entry| entry[:key] == section_key }
      return false unless section

      section[:questions].any? do |question|
        !responses[question[:key]]&.answered?
      end
    end

    def next_incomplete_section_key_for_session(responses)
      ContextIntake::QuestionnaireSchema.sections.find do |section|
        section[:questions].any? do |question|
          !responses[question[:key]]&.answered?
        end
      end&.fetch(:key, nil)
    end

    def abort_if_in_progress!
      existing = @project.context_intake_sessions.in_progress.first
      return unless existing

      redirect_to project_context_intake_path(@project),
        alert: "A questionnaire session is already in progress."
    end
  end
end
