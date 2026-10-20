# frozen_string_literal: true

class ChatInvestigations::RunJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @spec QUESTION-EXPLORATION-010 QUESTION-EXPLORATION-013
  def perform(investigation_id)
    ChatInvestigations::Run.call(investigation: ChatInvestigation.find(investigation_id))
  end
end
