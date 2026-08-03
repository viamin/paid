# frozen_string_literal: true

module FreeModels
  class QualityFilter
    FREE_MODEL_MINIMUM_CRITERIA = {
      min_context_window: 128_000,
      requires_tools: true
    }.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(context_window:, supports_tools:)
      @context_window = context_window.to_i
      @supports_tools = supports_tools == true
    end

    def call
      @context_window < FREE_MODEL_MINIMUM_CRITERIA[:min_context_window] ||
        (FREE_MODEL_MINIMUM_CRITERIA[:requires_tools] && !@supports_tools)
    end
  end
end
