# frozen_string_literal: true

module QualityMetrics
  # Delegates to QualityMetrics::Collect, which is the canonical automated
  # metrics collector. This class exists as a convenience alias to keep
  # call sites readable when the intent is explicitly "collect automated metrics".
  class CollectAutomated
    def self.call(agent_run:)
      QualityMetrics::Collect.call(agent_run: agent_run)
    end
  end
end
