# frozen_string_literal: true

class CodexLoginSessionsController < ApplicationController
  include ActiveRunnerCredentialStatus

  before_action :set_codex_login_session, only: [ :show, :update ]

  def new
    @flow_definition = flow_definition_for_new
    @codex_login_session = current_account.codex_login_sessions.build(
      created_by: current_user,
      credential_name: @flow_definition.credential_name
    )
    apply_return_to(@codex_login_session, params[:return_to])
    apply_target_runner_key(@codex_login_session, resolved_target_runner_key)
    @return_to_path = normalized_return_to(@codex_login_session.metadata["return_to"])
    load_active_credential_status(@codex_login_session.target_runner_key)
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
      @flow_definition = flow_definition_for_session(@codex_login_session)
      load_active_credential_status(@codex_login_session.target_runner_key)
      render :new, status: :unprocessable_content
    end
  end

  def show
    @flow_definition = flow_definition_for_session(@codex_login_session)
    @return_to_path = normalized_return_to(@codex_login_session.metadata["return_to"])
    authorize @codex_login_session
  end

  def update
    @flow_definition = flow_definition_for_session(@codex_login_session)
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
    params.require(:codex_login_session).permit(:credential_name, metadata: [ :return_to, :target_runner_key ]).tap do |permitted|
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
    target_runner_key = resolved_target_runner_key(metadata[:target_runner_key] || metadata["target_runner_key"])
    {}.tap do |result|
      result["return_to"] = return_to if return_to.present?
      result["target_runner_key"] = target_runner_key
    end
  end

  def apply_target_runner_key(session, runner_key)
    session.metadata = session.metadata.to_h.merge("target_runner_key" => runner_key)
  end

  def resolved_target_runner_key(candidate = params[:target_runner_key])
    RunnerLoginFlows::Registry.supported_target_runner_key(
      session_kind: "codex",
      candidate: candidate,
      fallback: "codex"
    )
  end

  def flow_definition_for_new
    RunnerLoginFlows::Registry.flow_for_session(
      session_kind: "codex",
      runner_key: resolved_target_runner_key
    )
  end

  def flow_definition_for_session(session)
    RunnerLoginFlows::Registry.flow_for_session(
      session_kind: "codex",
      runner_key: session.target_runner_key
    )
  end
end
