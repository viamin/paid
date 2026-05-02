# frozen_string_literal: true

class ChatSessionsController < ApplicationController
  skip_after_action :verify_authorized, only: :index
  before_action :set_chat_session, only: %i[show update destroy]

  rate_limit to: 10, within: 1.minute,
    by: -> { current_account&.id },
    with: -> { render json: { error: "Rate limit exceeded" }, status: :too_many_requests },
    only: :create

  def index
    respond_to do |format|
      format.html do
        load_sidebar_data
        @chat_messages = []
      end

      format.json do
        pagy, sessions = pagy(session_scope, limit: 25)
        render json: {
          sessions: sessions.map { |s| session_json(s) },
          pagination: pagination_meta(pagy)
        }
      end
    end
  end

  def create
    authorize ChatSession.new(account: current_account), :create?
    session = ChatSessions::Create.call(
      account: current_account,
      user: current_user,
      **create_params
    )

    respond_to do |format|
      format.html { redirect_to chat_session_path(session), notice: "Chat session created." }
      format.json { render json: session_json(session), status: :created }
    end
  end

  def show
    authorize @chat_session

    respond_to do |format|
      format.html do
        load_sidebar_data
        @pagy, @chat_messages = pagy(@chat_session.messages.chronological, limit: 50)
      end

      format.json do
        pagy, messages = pagy(@chat_session.messages.chronological, limit: 50)
        render json: session_json(@chat_session).merge(
          messages: messages.map { |m| message_json(m) },
          pagination: pagination_meta(pagy)
        )
      end
    end
  end

  def update
    authorize @chat_session
    @chat_session.update!(update_params)

    respond_to do |format|
      format.html { redirect_to chat_session_path(@chat_session), notice: "Chat session updated." }
      format.json { render json: session_json(@chat_session) }
    end
  end

  def destroy
    authorize @chat_session
    ChatSessions::Close.call(chat_session: @chat_session)

    respond_to do |format|
      format.html { redirect_to chat_sessions_path, notice: "Chat session closed." }
      format.json { head :no_content }
    end
  end

  private

  def set_chat_session
    @chat_session = session_scope.find(params[:id])
  end

  def create_params
    params.permit(:mode, :model, :provider_id, :project_id, :system_prompt, :title)
      .to_h.symbolize_keys
  end

  def update_params
    params.permit(:title, :model, :project_id, :provider_id)
  end

  def session_json(session)
    {
      id: session.id,
      external_id: session.external_id,
      title: session.title,
      status: session.status,
      mode: session.mode,
      model: session.model,
      provider_id: session.provider_id,
      provider_name: session.provider&.display_name,
      project_id: session.project_id,
      project_name: session.project&.name,
      created_by_id: session.created_by_id,
      created_at: session.created_at,
      updated_at: session.updated_at,
      total_tokens_input: session.total_tokens_input,
      total_tokens_output: session.total_tokens_output,
      estimated_cost_cents: session.estimated_cost_cents
    }
  end

  def message_json(message)
    {
      id: message.id,
      external_id: message.external_id,
      role: message.role,
      content: message.content,
      model: message.model,
      tool_call_id: message.tool_call_id,
      tool_name: message.tool_name,
      tool_arguments: message.tool_arguments,
      tool_result: message.tool_result,
      tokens_input: message.tokens_input,
      tokens_output: message.tokens_output,
      created_at: message.created_at
    }
  end

  def load_sidebar_data
    @sessions = session_scope.limit(50)
    @new_chat_session = ChatSession.new(mode: "api")
    @available_providers = current_user.providers.ordered
    @available_projects = current_account.projects.order(:name)
    @available_models = LlmModel.active.order(:provider, :display_name)
  end

  def session_scope
    policy_scope(ChatSession)
      .includes(:project, :provider, :chat_session_projects, :projects)
      .order(updated_at: :desc)
  end

  def pagination_meta(pagy)
    { page: pagy.page, pages: pagy.pages, count: pagy.count }
  end
end
