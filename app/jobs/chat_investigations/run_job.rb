# frozen_string_literal: true

class ChatInvestigations::RunJob < ApplicationJob
  queue_as :low_priority

  # Experiments may provision a container and seed its workspace. Keep that
  # external I/O away from the interactive chat queue and bound a stuck run.
  self.perform_timeout = 15.minutes

  discard_on ActiveRecord::RecordNotFound

  # @spec QUESTION-EXPLORATION-010 QUESTION-EXPLORATION-013
  def perform(investigation_id)
    ChatInvestigations::Run.call(investigation: ChatInvestigation.find(investigation_id))
  end

  private

  def tenant_account
    ChatInvestigation.find_by(id: arguments.first)&.account
  end
end
