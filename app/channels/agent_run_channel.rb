# frozen_string_literal: true

class AgentRunChannel < ApplicationCable::Channel
  def subscribed
    agent_run = AgentRun.find_by(id: params[:id])
    reject unless agent_run && authorized?(agent_run)
    stream_for agent_run
  end

  private

  def authorized?(agent_run)
    agent_run.project.account_id == current_user.account_id
  end
end
