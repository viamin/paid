# frozen_string_literal: true

module Configuration
  module Profiles
    # A single deterministic setting transition produced by {Planner} and
    # applied by {Applier}. Value-equal (two changes with the same key/from/to
    # are equal), so plans can be compared and de-duplicated.
    class Change < Data.define(:key, :from, :to, :level)
      def description
        "#{key}: #{inspect_value(from)} -> #{inspect_value(to)}"
      end

      private

      def inspect_value(value)
        value.nil? ? "nil" : value.inspect
      end
    end
  end
end
