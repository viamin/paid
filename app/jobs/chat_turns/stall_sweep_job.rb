# frozen_string_literal: true

module ChatTurns
  class StallSweepJob < ApplicationJob
    queue_as :maintenance

    def perform
      TenantContext.with_system_access { DetectStalls.call }
    end
  end
end
