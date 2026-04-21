# frozen_string_literal: true

class PoolReplenishmentJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: -> { "container_pool_replenishment_#{arguments.first || "all"}" }
  )

  def perform(project_id = nil)
    projects(project_id).find_each do |project|
      Containers::PoolManager.new(project: project).replenish
    end
  end

  private

  def projects(project_id)
    scope = Project.active
    project_id.present? ? scope.where(id: project_id) : scope
  end
end
