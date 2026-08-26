# frozen_string_literal: true

module PageLoadPerformance
  module Median
    def self.of(values)
      sorted = Array(values).compact.sort
      return nil if sorted.empty?

      middle = sorted.size / 2
      return sorted[middle] if sorted.size.odd?

      ((sorted[middle - 1] + sorted[middle]) / 2.0).round
    end
  end
end
