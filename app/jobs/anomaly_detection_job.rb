# frozen_string_literal: true

class AnomalyDetectionJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  def perform(agent_run_id)
    agent_run = AgentRun.find(agent_run_id)
    return unless agent_run.finished?

    Anomalies::Detect.call(agent_run)
  end
end
