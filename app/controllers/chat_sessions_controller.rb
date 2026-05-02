# frozen_string_literal: true

class ChatSessionsController < ApplicationController
  skip_after_action :verify_authorized, only: %i[index sidebar_page]
  before_action :set_chat_session, only: %i[show update destroy older_messages]

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

  def older_messages
    authorize @chat_session, :show?
    before_id = params.require(:before)
    frame_id = request.headers["Turbo-Frame"].presence || "older_messages"
    messages = @chat_session.messages.chronological
      .where("chat_messages.id < ?", before_id)
      .last(50)

    has_more = @chat_session.messages.where("chat_messages.id < ?", messages.first&.id).exists? if messages.any?

    render partial: "chat_sessions/older_messages",
      locals: { messages: messages, chat_session: @chat_session, has_more: has_more, frame_id: frame_id }
  end

  def sidebar_page
    page = [ params.fetch(:page, 1).to_i, 1 ].max
    @sessions = session_scope.offset((page - 1) * 50).limit(51)
    has_more = @sessions.size > 50
    @sessions = @sessions.first(50)
    @next_page = has_more ? page + 1 : nil

    render partial: "chat_sessions/sidebar_page", locals: { sessions: @sessions, current_page: page, next_page: @next_page }
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
        scope = @chat_session.messages.chronological
        total = scope.count
        last_page = [ (total.to_f / 50).ceil, 1 ].max
        @pagy, @chat_messages = pagy(scope, limit: 50, page: last_page)
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
    source = params.key?(:chat_session) ? params.require(:chat_session) : params
    source.permit(:mode, :model, :provider_id, :project_id, :system_prompt, :title)
      .to_h.symbolize_keys
  end

  def update_params
    params.fetch(:chat_session, params).permit(:title, :model, :project_id, :provider_id)
  end

  def session_json(session)
    projects = session_projects(session)

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
      project_name: session.project&.name || projects.first&.name,
      project_names: projects.map(&:name),
      created_by_id: session.created_by_id,
      created_at: session.created_at,
      updated_at: session.updated_at,
      total_tokens_input: session.try(:preloaded_tokens_input) || session.total_tokens_input,
      total_tokens_output: session.try(:preloaded_tokens_output) || session.total_tokens_output,
      estimated_cost_cents: session.try(:preloaded_cost_cents) || session.estimated_cost_cents
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
    @sessions = session_scope.limit(51)
    @sidebar_has_more = @sessions.size > 50
    @sessions = @sessions.first(50)
    @new_chat_session = ChatSession.new(mode: "api")
    @available_providers = current_user.providers.ordered
    @available_projects = current_account.projects.order(:name)
    @available_models = LlmModel.active.order(:provider, :display_name)
  end

  def session_scope
    policy_scope(ChatSession)
      .with_preview_content
      .select(
        "chat_sessions.*",
        "(SELECT COALESCE(SUM(input_tokens),0) FROM token_usages WHERE token_usages.chat_session_id = chat_sessions.id) AS preloaded_tokens_input",
        "(SELECT COALESCE(SUM(output_tokens),0) FROM token_usages WHERE token_usages.chat_session_id = chat_sessions.id) AS preloaded_tokens_output",
        "(SELECT COALESCE(SUM(cost_cents),0) FROM token_usages WHERE token_usages.chat_session_id = chat_sessions.id) AS preloaded_cost_cents"
      )
      .includes(:project, :provider, :chat_session_projects, :projects)
      .order(updated_at: :desc)
  end

  def pagination_meta(pagy)
    { page: pagy.page, pages: pagy.pages, count: pagy.count }
  end

  def session_projects(session)
    (session.projects.to_a + [ session.project ].compact).uniq(&:id)
  end
end
