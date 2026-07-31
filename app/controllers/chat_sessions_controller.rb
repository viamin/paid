# frozen_string_literal: true

class ChatSessionsController < ApplicationController
  CREATE_RATE_LIMIT = 10
  CREATE_RATE_LIMIT_PERIOD = 1.minute
  CREATE_RATE_LIMIT_FALLBACK_CACHE = ActiveSupport::Cache::MemoryStore.new
  MESSAGE_PAGE_SIZE = 50
  SIDEBAR_PAGE_SIZE = 50

  skip_after_action :verify_authorized, only: %i[index sidebar_page]
  before_action :set_chat_session, only: %i[show update destroy archive unarchive older_messages]
  before_action :reject_archived_chat_session, only: %i[update destroy archive]
  before_action :enforce_create_rate_limit, only: :create
  before_action :default_request_format_to_json, only: %i[index create show update destroy archive unarchive]

  def index
    respond_to do |format|
      format.html do
        existing = policy_scope(ChatSession).where(status: "active").order(updated_at: :desc).first
        if existing
          skip_policy_scope
          redirect_to chat_session_path(existing)
        elsif policy(ChatSession.new(account: current_account)).create?
          return render_create_rate_limit_exceeded if create_rate_limited?

          session = ChatSessions::Create.call(
            account: current_account,
            user: current_user
          )
          skip_policy_scope
          redirect_to chat_session_path(session)
        else
          load_sidebar_data
          @chat_messages = []
        end
      end

      format.json do
        pagy, sessions = pagy(session_scope_with_token_totals, limit: 25)
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
    messages = latest_messages(
      @chat_session.messages.chronological.where("chat_messages.id < ?", before_id)
    )

    has_more = @chat_session.messages.where("chat_messages.id < ?", messages.first&.id).exists? if messages.any?

    render partial: "chat_sessions/older_messages",
      locals: { messages: messages, chat_session: @chat_session, has_more: has_more, frame_id: frame_id }
  end

  def sidebar_page
    archived = archived_param?
    sidebar = sidebar_batch(
      archived: archived,
      before_updated_at: params[:before_updated_at],
      before_id: params[:before_id],
      exclude_id: params[:exclude_id]
    )

    locals = {
      sessions: sidebar[:sessions],
      frame_id: request.headers["Turbo-Frame"].presence || sidebar[:frame_id],
      sidebar_has_more: sidebar[:next_frame_id].present?,
      sidebar_next_frame_id: sidebar[:next_frame_id],
      sidebar_next_params: sidebar[:next_params]
    }

    if sidebar_toggle_request?
      render partial: "chat_sessions/sidebar_list", locals: locals.merge(archived_view: archived)
    else
      render partial: "chat_sessions/sidebar_page", locals: {
        sessions: locals[:sessions],
        frame_id: locals[:frame_id],
        next_frame_id: locals[:sidebar_next_frame_id],
        next_params: locals[:sidebar_next_params]
      }
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
  rescue ArgumentError => e
    respond_to do |format|
      format.html { redirect_to chat_sessions_path, alert: e.message }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def show
    authorize @chat_session

    respond_to do |format|
      format.html do
        load_chat_messages

        if popup_request?
          render partial: "chat_sessions/popup", locals: {
            chat_session: @chat_session,
            chat_messages: @chat_messages,
            has_older_messages: @has_older_messages
          }
        else
          load_sidebar_data(active_session: @chat_session)
        end
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
    project_changed = update_params.key?(:project_id) && update_params[:project_id].to_s != @chat_session.project_id.to_s
    metadata_changed = update_params.key?(:metadata) && update_params[:metadata] != @chat_session.metadata
    @chat_session.update!(update_params)
    regenerate_system_message! if project_changed || metadata_changed

    respond_to do |format|
      format.html { redirect_to chat_session_path(@chat_session), notice: "Chat session updated." }
      format.json { render json: session_json(@chat_session) }
    end
  end

  def destroy
    authorize @chat_session
    ChatSessions::Close.call(chat_session: @chat_session)

    respond_to do |format|
      format.html do
        next_session = policy_scope(ChatSession).where(status: "active").where.not(id: @chat_session.id).order(updated_at: :desc).first
        if next_session
          redirect_to chat_session_path(next_session), notice: "Chat session closed."
        else
          redirect_to chat_sessions_path, notice: "Chat session closed."
        end
      end
      format.json { head :no_content }
    end
  end

  def archive
    authorize @chat_session, :archive?
    ChatSessions::Archive.call(chat_session: @chat_session)

    respond_to do |format|
      format.html { redirect_after_archive }
      format.json { render json: session_json(@chat_session) }
    end
  end

  def unarchive
    authorize @chat_session, :unarchive?
    ChatSessions::Unarchive.call(chat_session: @chat_session)

    respond_to do |format|
      format.html { redirect_to chat_session_path(@chat_session), notice: "Chat session restored." }
      format.json { render json: session_json(@chat_session) }
    end
  end

  private

  def set_chat_session
    @chat_session = member_scope.find(params[:id])
  end

  def reject_archived_chat_session
    return unless @chat_session&.archived?

    respond_to do |format|
      format.html { redirect_to chat_session_path(@chat_session), alert: "Chat session is archived." }
      format.json { render json: { error: "Chat session is archived." }, status: :unprocessable_entity }
    end
  end

  def regenerate_system_message!
    new_prompt = ChatSessions::BuildSystemPrompt.call(chat_session: @chat_session.reload)
    system_message = @chat_session.messages.where(role: "system").order(:created_at).first
    system_message&.update!(content: new_prompt)
  end

  def create_params
    source = params.key?(:chat_session) ? params.require(:chat_session) : params
    permitted = source.permit(
      :container_capability,
      :mode,
      :model,
      :runner_id,
      :provider_id,
      :project_id,
      :system_prompt,
      :title,
      :auto_approve,
      metadata: {}
    )
      .to_h.symbolize_keys
    permitted[:runner_id] ||= permitted.delete(:provider_id)
    normalize_legacy_create_params!(permitted)
    permitted
  end

  def update_params
    permitted = params.fetch(:chat_session, params).permit(:title, :model, :project_id, :runner_id, :provider_id, :auto_approve, metadata: {})
      .to_h.symbolize_keys
    permitted[:runner_id] ||= permitted.delete(:provider_id)
    permitted
  end

  def normalize_legacy_create_params!(permitted)
    mode = permitted.delete(:mode).presence
    return unless mode
    return if permitted[:container_capability].present?

    permitted[:container_capability] = container_capability_for_legacy_mode(mode)
  end

  def container_capability_for_legacy_mode(mode)
    case mode
    when "api" then "none"
    when "workspace" then "pending"
    else
      raise ArgumentError, "mode must be one of api, workspace"
    end
  end

  def session_json(session)
    projects = session_projects(session)

    {
      id: session.id,
      external_id: session.external_id,
      title: session.title,
      status: session.status,
      container_capability: session.container_capability,
      container_requested_at: session.container_requested_at,
      container_ready_at: session.container_ready_at,
      model: session.model,
      runner_id: session.runner_id,
      runner_name: session.runner&.display_name,
      project_id: session.project_id,
      project_name: session.project&.name || projects.first&.name,
      project_names: projects.map(&:name),
      auto_approve: session.auto_approve?,
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

  def session_scope(archived: false)
    scoped = policy_scope(ChatSession).with_preview_content
    scoped = archived ? scoped.archived_only : scoped.visible
    scoped.includes(:project, :runner, :chat_session_projects, :projects)
      .order(updated_at: :desc, id: :desc)
  end

  def member_scope
    policy_scope(ChatSession)
      .with_preview_content
      .includes(:project, :runner, :chat_session_projects, :projects)
      .order(updated_at: :desc, id: :desc)
  end

  def session_scope_with_token_totals
    policy_scope(ChatSession)
      .visible
      .with_preview_content
      .select(
        "chat_sessions.*",
        "(SELECT COALESCE(SUM(input_tokens),0) FROM token_usages WHERE token_usages.chat_session_id = chat_sessions.id) AS preloaded_tokens_input",
        "(SELECT COALESCE(SUM(output_tokens),0) FROM token_usages WHERE token_usages.chat_session_id = chat_sessions.id) AS preloaded_tokens_output",
        "(SELECT COALESCE(SUM(cost_cents),0) FROM token_usages WHERE token_usages.chat_session_id = chat_sessions.id) AS preloaded_cost_cents"
      )
      .includes(:project, :runner, :chat_session_projects, :projects)
      .order(updated_at: :desc, id: :desc)
  end

  def pagination_meta(pagy)
    { page: pagy.page, pages: pagy.pages, count: pagy.count }
  end

  def redirect_after_archive
    next_session = session_scope.where.not(id: @chat_session.id).first
    target = next_session ? chat_session_path(next_session) : chat_sessions_path

    redirect_to target, notice: "Chat session archived."
  end

  def session_projects(session)
    (session.projects.to_a + [ session.project ].compact).uniq(&:id)
  end

  def render_create_rate_limit_exceeded
    respond_to do |format|
      format.turbo_stream { redirect_back fallback_location: chat_sessions_path, alert: "Rate limit exceeded" }
      format.html { redirect_back fallback_location: chat_sessions_path, alert: "Rate limit exceeded" }
      format.json { render json: { error: "Rate limit exceeded" }, status: :too_many_requests }
    end
  end

  def latest_messages(scope, limit: MESSAGE_PAGE_SIZE)
    scope.reorder(created_at: :desc, id: :desc).limit(limit).reverse
  end

  def create_rate_limited?
    key = "chat_sessions:create:#{current_account&.id}"
    count = increment_rate_limit_counter(
      cache: create_rate_limit_cache,
      key:,
      expires_in: CREATE_RATE_LIMIT_PERIOD
    )
    count > CREATE_RATE_LIMIT
  end

  def enforce_create_rate_limit
    render_create_rate_limit_exceeded if create_rate_limited?
  end

  def default_request_format_to_json
    return if params[:format].present?
    return if request.headers["Accept"].to_s.include?("text/html")
    return if request.headers["Accept"].to_s.include?("application/json")
    return if request.headers["Accept"].to_s.include?("text/vnd.turbo-stream.html")

    request.format = :json
  end

  def load_sidebar_data(active_session: nil)
    archived = sidebar_view_archived?(active_session)
    sidebar = sidebar_batch(archived: archived)
    if active_session_in_view?(active_session, archived) && active_session_needs_pinning?(active_session:, sessions: sidebar[:sessions])
      sidebar = pinned_sidebar_batch(active_session, archived: archived)
    end

    @archived_view = archived
    @sessions = sidebar[:sessions]
    @sidebar_has_more = sidebar[:next_frame_id].present?
    @sidebar_next_frame_id = sidebar[:next_frame_id]
    @sidebar_next_params = sidebar[:next_params]
    @new_chat_session = ChatSession.new(container_capability: "none", auto_approve: current_user.settings.default_auto_approve)
    @available_runners = current_user.runners.kept_only.ordered
    @available_projects = current_account.projects.order(:name)
    @available_models = LlmModel.active.order(:provider, :display_name)
  end

  def load_chat_messages
    scope = @chat_session.messages.chronological
    @chat_messages = latest_messages(scope)
    @has_older_messages = scope.where("chat_messages.id < ?", @chat_messages.first.id).exists? if @chat_messages.any?
  end

  def popup_request?
    params[:display] == "popup"
  end

  def pinned_sidebar_batch(active_session, archived:)
    sidebar = sidebar_batch(archived: archived, limit: SIDEBAR_PAGE_SIZE - 1, exclude_id: active_session.id)

    {
      sessions: [ active_session ] + sidebar[:sessions],
      next_frame_id: sidebar[:next_frame_id],
      next_params: sidebar[:next_params]
    }
  end

  def active_session_needs_pinning?(active_session:, sessions:)
    active_session.present? && sessions.none? { |session| session.id == active_session.id }
  end

  def active_session_in_view?(active_session, archived)
    active_session.present? && active_session.archived? == archived
  end

  def sidebar_batch(archived: archived_param?, before_updated_at: nil, before_id: nil, exclude_id: nil, limit: SIDEBAR_PAGE_SIZE)
    sessions = apply_sidebar_cursor(
      session_scope(archived: archived),
      before_updated_at:,
      before_id:,
      exclude_id:
    ).limit(limit + 1).to_a

    visible_sessions = sessions.first(limit)
    cursor_session = visible_sessions.last if sessions.size > limit

    {
      sessions: visible_sessions,
      frame_id: sidebar_frame_id(before_updated_at:, before_id:),
      next_frame_id: cursor_session ? sidebar_frame_id(before_updated_at: cursor_session.updated_at.iso8601(6), before_id: cursor_session.id) : nil,
      next_params: cursor_session ? sidebar_cursor_params(cursor_session, exclude_id:, archived:) : nil
    }
  end

  def apply_sidebar_cursor(scope, before_updated_at:, before_id:, exclude_id:)
    scoped = exclude_id.present? ? scope.where.not(id: exclude_id) : scope
    return scoped if before_updated_at.blank? || before_id.blank?

    scoped.where(
      "chat_sessions.updated_at < :updated_at OR (chat_sessions.updated_at = :updated_at AND chat_sessions.id < :id)",
      updated_at: Time.iso8601(before_updated_at),
      id: before_id
    )
  rescue ArgumentError
    scoped.none
  end

  def sidebar_cursor_params(session, exclude_id:, archived:)
    {
      before_updated_at: session.updated_at.iso8601(6),
      before_id: session.id,
      exclude_id:,
      archived: archived ? "true" : nil
    }.compact
  end

  def sidebar_frame_id(before_updated_at:, before_id:)
    return "sidebar_page_1" if before_updated_at.blank? || before_id.blank?

    "sidebar_page_#{before_id}"
  end

  def archived_param?
    params[:archived] == "true"
  end

  def sidebar_view_archived?(active_session)
    return archived_param? if params.key?(:archived)

    active_session&.archived? || false
  end

  def sidebar_toggle_request?
    params[:before_updated_at].blank? && params[:before_id].blank?
  end

  def increment_rate_limit_counter(cache:, key:, expires_in:)
    count = cache.increment(key, 1, expires_in: expires_in)
    return count unless count.nil?

    cache.write(key, 0, expires_in: expires_in, unless_exist: true)
    cache.increment(key, 1, expires_in: expires_in) || 1
  end

  def create_rate_limit_cache
    Rails.cache.is_a?(ActiveSupport::Cache::NullStore) ? CREATE_RATE_LIMIT_FALLBACK_CACHE : Rails.cache
  end
end
