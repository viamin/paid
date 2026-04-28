# frozen_string_literal: true

class ChatSessionsController < ApplicationController
  skip_after_action :verify_authorized, only: :index
  before_action :set_chat_session, only: %i[show update destroy]

  rate_limit to: 10, within: 1.minute,
    by: -> { current_account&.id },
    with: -> { render json: { error: "Rate limit exceeded" }, status: :too_many_requests },
    only: :create

  def index
    sessions = policy_scope(ChatSession)
      .order(updated_at: :desc)
    render json: sessions.map { |s| session_json(s) }
  end

  def create
    authorize current_account.chat_sessions.build, :create?
    session = ChatSessions::Create.call(
      account: current_account,
      user: current_user,
      **create_params
    )
    render json: session_json(session), status: :created
  end

  def show
    authorize @chat_session
    pagy, messages = pagy(@chat_session.messages.chronological, limit: 50)
    render json: session_json(@chat_session).merge(
      messages: messages.map { |m| message_json(m) },
      pagination: pagination_meta(pagy)
    )
  end

  def update
    authorize @chat_session
    @chat_session.update!(update_params)
    render json: session_json(@chat_session)
  end

  def destroy
    authorize @chat_session
    ChatSessions::Close.call(chat_session: @chat_session)
    head :no_content
  end

  private

  def set_chat_session
    @chat_session = policy_scope(ChatSession).find(params[:id])
  end

  def create_params
    params.permit(:mode, :model, :provider_id, :project_id, :system_prompt, :title)
      .to_h.symbolize_keys
  end

  def update_params
    params.permit(:title, :model, :project_id)
  end

  def session_json(session)
    {
      id: session.id,
      external_id: session.external_id,
      title: session.title,
      status: session.status,
      mode: session.mode,
      model: session.model,
      project_id: session.project_id,
      created_by_id: session.created_by_id,
      created_at: session.created_at,
      updated_at: session.updated_at
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
      tokens_input: message.tokens_input,
      tokens_output: message.tokens_output,
      created_at: message.created_at
    }
  end

  def pagination_meta(pagy)
    { page: pagy.page, pages: pagy.pages, count: pagy.count }
  end
end
