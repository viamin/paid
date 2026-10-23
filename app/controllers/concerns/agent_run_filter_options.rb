# frozen_string_literal: true

module AgentRunFilterOptions
  private

  def available_filter_options(scope, cache_key:)
    scope.distinct_filter_options(cache_key: cache_key)
  end
end
