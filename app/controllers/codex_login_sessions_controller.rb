# frozen_string_literal: true

class CodexLoginSessionsController < ApplicationController
  include ActiveRunnerCredentialStatus

  before_action :set_codex_login_session, only: [ :show, :update ]

  def new
    @codex_login_session = current_account.codex_login_sessions.build(
      created_by: current_user,
      credential_name: "Codex Connect Login"
    )
    apply_return_to(@codex_login_session, params[:return_to])
    @return_to_path = normalized_return_to(@codex_login_session.metadata["return_to"])
    load_active_credential_status("codex")
    authorize @codex_login_session
  end

  def create
    @codex_login_session = current_account.codex_login_sessions.build(codex_login_session_params)
    @codex_login_session.created_by = current_user
    authorize @codex_login_session

    if @codex_login_session.save
      CodexLoginSessions::DeviceFlow.call(session: @codex_login_session)
      redirect_to codex_login_session_path(@codex_login_session.external_id)
    else
      load_active_credential_status("codex")
      render :new, status: :unprocessable_content
    end
  end

  def show
    @return_to_path = normalized_return_to(@codex_login_session.metadata["return_to"])
    authorize @codex_login_session
  end

  def update
    authorize @codex_login_session
    result = CodexLoginSessions::DeviceFlow.new(session: @codex_login_session).poll!(
      session_token: params[:session_token]
    )

    if result[:completed]
      redirect_to codex_login_session_path(@codex_login_session.external_id),
        notice: "Codex credential captured from the device-code login."
    elsif result[:status] == :failed
      flash.now[:alert] = result[:error]
      render :show, status: :unprocessable_content
    else
      redirect_to codex_login_session_path(@codex_login_session.external_id),
        notice: "Authorization still pending — complete the login in your browser, then check again."
    end
  end

  private

  def set_codex_login_session
    @codex_login_session = policy_scope(CodexLoginSession).find_by!(external_id: params[:id])
  end

  def codex_login_session_params
    params.require(:codex_login_session).permit(:credential_name, metadata: [ :return_to ]).tap do |permitted|
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

    parsed = URI.parse(candidate.to_s)
    return unless parsed.scheme.nil? && parsed.host.nil?
    return unless candidate.to_s.start_with?("/") && !candidate.to_s.start_with?("//")

    candidate.to_s
  rescue URI::InvalidURIError
    nil
  end
end
