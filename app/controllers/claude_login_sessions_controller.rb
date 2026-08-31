# frozen_string_literal: true

class ClaudeLoginSessionsController < ApplicationController
  include ActiveRunnerCredentialStatus

  before_action :set_claude_login_session, only: [ :show, :update ]

  def new
    @flow_definition = flow_definition_for_new
    @claude_login_session = ClaudeLoginSession.new(
      account: current_account,
      created_by: current_user,
      credential_name: @flow_definition.credential_name
    )
    apply_return_to(@claude_login_session, params[:return_to])
    apply_target_runner_key(@claude_login_session, resolved_target_runner_key)
    @return_to_path = normalized_return_to(@claude_login_session.metadata["return_to"])
    load_active_credential_status(@claude_login_session.target_runner_key)
    authorize @claude_login_session
  end

  def create
    @claude_login_session = ClaudeLoginSession.new(claude_login_session_params)
    @claude_login_session.account = current_account
    @claude_login_session.created_by = current_user
    authorize @claude_login_session

    if @claude_login_session.save
      ClaudeLoginSessions::Start.call(session: @claude_login_session)
      redirect_to claude_login_session_path(@claude_login_session.external_id)
    else
      @flow_definition = flow_definition_for_session(@claude_login_session)
      load_active_credential_status(@claude_login_session.target_runner_key)
      render :new, status: :unprocessable_content
    end
  end

  def show
    @flow_definition = flow_definition_for_session(@claude_login_session)
    @return_to_path = normalized_return_to(@claude_login_session.metadata["return_to"])
    authorize @claude_login_session
  end

  def update
    @flow_definition = flow_definition_for_session(@claude_login_session)
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
    params.require(:claude_login_session).permit(:credential_name, metadata: [ :return_to, :target_runner_key ]).tap do |permitted|
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
      session_kind: "claude",
      candidate: candidate,
      fallback: "claude"
    )
  end

  def flow_definition_for_new
    RunnerLoginFlows::Registry.flow_for_session(
      session_kind: "claude",
      runner_key: resolved_target_runner_key
    )
  end

  def flow_definition_for_session(session)
    RunnerLoginFlows::Registry.flow_for_session(
      session_kind: "claude",
      runner_key: session.target_runner_key
    )
  end
end
