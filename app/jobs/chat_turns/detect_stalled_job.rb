# frozen_string_literal: true

module ChatTurns
  class DetectStalledJob < ApplicationJob
    queue_as :maintenance

    def perform
      TenantContext.with_system_access { ChatTurns::DetectStalled.call }
    end
  end
end
