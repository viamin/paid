# frozen_string_literal: true

class ChatTurnsController < ApplicationController
  before_action :set_chat_session

  def recover
    authorize ChatMessage.new(chat_session: @chat_session), policy_class: ChatMessagePolicy
    turn = @chat_session.chat_turns.find(params[:id])
    assistant_message = with_chat_session_tenant_context do
      ChatSessions::ResumeStalledTurn.call(chat_turn: turn, actor: current_user)
    end

    render json: { status: assistant_message ? "completed" : "paused", chat_turn_id: turn.id }
  rescue ChatSessions::ResumeStalledTurn::RecoveryConflictError => error
    render json: { error: error.message }, status: :conflict
  rescue AgentHarness::Error => error
    render json: { error: ChatSessions::ErrorMessage.for(error) }, status: :bad_gateway
  end

  private

  def set_chat_session
    @chat_session = policy_scope(ChatSession).find(params[:chat_session_id])
  end

  def with_chat_session_tenant_context(&)
    account = TenantContext.with_system_access { Account.find(@chat_session.account_id) }
    TenantContext.with(account, &)
  end
end
