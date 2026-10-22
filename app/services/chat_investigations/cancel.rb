# frozen_string_literal: true

module ChatInvestigations
  class Cancel
    def self.call(...)
      new(...).call
    end

    def initialize(investigation:, actor:)
      @investigation = investigation
      @actor = actor
    end

    def call
      investigation.with_lock do
        return investigation unless investigation.active?

        investigation.update!(status: "cancelled", cancelled_at: Time.current, finished_at: Time.current,
          reserved_cost_cents: 0, metadata: investigation.metadata.merge("cancelled_by_id" => actor.id))
      end
      ChatInvestigations::Broadcast.call(investigation)
      investigation
    end

    private

    attr_reader :actor, :investigation
  end
end
