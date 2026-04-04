# frozen_string_literal: true

class QualityMetricsCollectionJob < ApplicationJob
  queue_as :metrics

  def perform(agent_run_id)
    agent_run = AgentRun.find(agent_run_id)
    return unless agent_run.finished?

    QualityMetrics::Collect.call(agent_run: agent_run)
  end
end
