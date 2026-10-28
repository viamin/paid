# frozen_string_literal: true

class ChatTurns::DetectStalledJob < ApplicationJob
  queue_as :maintenance

  def perform
    TenantContext.with_system_access { ChatTurns::DetectStalled.call }
  end
end
