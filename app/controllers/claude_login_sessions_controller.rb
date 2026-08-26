# frozen_string_literal: true

class ClaudeLoginSessionsController < ApplicationController
  include ActiveRunnerCredentialStatus

  before_action :set_claude_login_session, only: [ :show, :update ]

  def new
    @claude_login_session = current_account.claude_login_sessions.build(
      created_by: current_user,
      credential_name: "Claude Browser Login"
    )
    apply_return_to(@claude_login_session, params[:return_to])
    @return_to_path = normalized_return_to(@claude_login_session.metadata["return_to"])
    load_active_credential_status("claude")
    authorize @claude_login_session
  end

  def create
    @claude_login_session = current_account.claude_login_sessions.build(claude_login_session_params)
    @claude_login_session.created_by = current_user
    authorize @claude_login_session

    if @claude_login_session.save
      ClaudeLoginSessions::Start.call(session: @claude_login_session)
      redirect_to claude_login_session_path(@claude_login_session.external_id)
    else
      load_active_credential_status("claude")
      render :new, status: :unprocessable_content
    end
  end

  def show
    @return_to_path = normalized_return_to(@claude_login_session.metadata["return_to"])
    authorize @claude_login_session
  end

  def update
    authorize @claude_login_session
    result = ClaudeLoginSessions::SubmitCode.call(
      session: @claude_login_session,
      session_token: params[:session_token],
      code: params[:authorization_code]
    )

    if result.success?
      redirect_to claude_login_session_path(@claude_login_session.external_id), notice: "Browser code submitted to the live Claude login session."
    else
      flash.now[:alert] = result.error_message
      render :show, status: :unprocessable_content
    end
  end

  private

  def set_claude_login_session
    @claude_login_session = policy_scope(ClaudeLoginSession).find_by!(external_id: params[:id])
  end

  def claude_login_session_params
    params.require(:claude_login_session).permit(:credential_name, metadata: [ :return_to ]).tap do |permitted|
      permitted[:metadata] = sanitized_metadata(permitted[:metadata])
    end
  end

  def apply_return_to(session, raw_return_to)
    sanitized_return_to = normalized_return_to(raw_return_to)
    session.metadata = session.metadata.to_h

    if sanitized_return_to.present?
      session.metadata["return_to"] = sanitized_return_to
    else
      session.metadata.delete("return_to")
    end
  end

  def sanitized_metadata(metadata)
    return {} if metadata.blank?

    return_to = normalized_return_to(metadata[:return_to] || metadata["return_to"])
    return_to.present? ? { "return_to" => return_to } : {}
  end

  def normalized_return_to(candidate)
    return if candidate.blank?

    candidate = candidate.to_s
    return unless candidate.start_with?("/") && !candidate.start_with?("//")

    url_from(candidate)
  rescue URI::InvalidURIError
    nil
  end
end
