# frozen_string_literal: true

# Cycle breaker repairs apply recommendations from cycle analysis to resolve
# dependency cycles. A repair is initiated with a pending_sync status, then
# automatically confirmed once the changes are synchronized to GitHub.
# Repairs are bounded by attempt count to prevent infinite retry loops.
module CycleBreakers
  def self.max_repair_attempts
    3
  end
end
