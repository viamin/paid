# frozen_string_literal: true

# @spec MAIN-CI-001 MAIN-CI-007
class MainCiReconciliationJob < ApplicationJob
  queue_as :default
  self.perform_timeout = 120

  def perform(project_id)
    project = Project.find_by(id: project_id)
    MainCi::Reconcile.call(project: project) if project&.active?
  end
end
