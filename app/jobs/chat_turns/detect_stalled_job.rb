# frozen_string_literal: true

class ChatTurns::DetectStalledJob < ApplicationJob
  queue_as :default

  include GoodJob::ActiveJobExtensions::Concurrency
  good_job_control_concurrency_with(total_limit: 1, key: -> { "chat-turn-stall-detector" })

  def perform
    ChatTurns::DetectStalled.call
  end
end
