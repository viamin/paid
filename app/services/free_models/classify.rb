# frozen_string_literal: true

module FreeModels
  class Classify
    Result = Struct.new(:score, :tier, keyword_init: true)

    BASE_SCORE = 3.0
    HIGH_TIER_THRESHOLD = 8.0
    MID_TIER_THRESHOLD = 6.0

    def self.call(...)
      new(...).call
    end

    def initialize(context_window:, max_output_tokens:, supports_tools:, supports_reasoning:, multimodal:)
      @context_window = context_window.to_i
      @max_output_tokens = max_output_tokens.to_i
      @supports_tools = supports_tools == true
      @supports_reasoning = supports_reasoning == true
      @multimodal = multimodal == true
    end

    def call
      score = BASE_SCORE
      score += context_window_bonus
      score += 2.0 if @supports_tools
      score += 1.5 if @supports_reasoning
      score += output_bonus
      score += 1.0 if @multimodal
      score = [ score, 10.0 ].min

      Result.new(score: score.round(2), tier: tier_for(score))
    end

    private

    def context_window_bonus
      return 3.0 if @context_window >= 1_000_000
      return 2.0 if @context_window >= 256_000
      return 1.0 if @context_window >= 128_000

      0.0
    end

    def output_bonus
      return 1.0 if @max_output_tokens >= 100_000
      return 0.5 if @max_output_tokens >= 32_000

      0.0
    end

    def tier_for(score)
      return "high" if score >= HIGH_TIER_THRESHOLD
      return "mid" if score >= MID_TIER_THRESHOLD

      "low"
    end
  end
end
