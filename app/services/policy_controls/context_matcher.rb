# frozen_string_literal: true

module PolicyControls
  class ContextMatcher
    def self.matches?(conditions:, context:)
      new(conditions:, context:).matches?
    end

    def initialize(conditions:, context:)
      @conditions = normalize_hash(conditions)
      @context = normalize_hash(context)
    end

    def matches?
      return true if conditions.empty?

      conditions.all? do |key, expected|
        match_condition?(key, expected)
      end
    end

    private

    attr_reader :conditions, :context

    def match_condition?(key, expected)
      case key
      when "risk_score_gte"
        numeric_context("risk_score") >= expected.to_f
      when "risk_score_lte"
        numeric_context("risk_score") <= expected.to_f
      when "issue_labels_any"
        overlap?(array_context("issue_labels"), Array(expected))
      when "issue_labels_all"
        subset?(Array(expected), array_context("issue_labels"))
      when "change_surface_any"
        overlap?(array_context("change_surface"), Array(expected))
      when "change_surface_all"
        subset?(Array(expected), array_context("change_surface"))
      else
        value_matches?(expected, context[key])
      end
    end

    def numeric_context(key)
      context[key].to_f
    end

    def array_context(key)
      Array(context[key]).map(&:to_s)
    end

    def overlap?(actual, expected)
      actual.intersection(expected.map(&:to_s)).any?
    end

    def subset?(expected, actual)
      expected.map(&:to_s).all? { |value| actual.include?(value) }
    end

    def value_matches?(expected, actual)
      case expected
      when Hash
        actual.is_a?(Hash) && self.class.matches?(conditions: expected, context: actual)
      when Array
        return true if expected.map(&:to_s).include?("any")

        actual_values = actual.is_a?(Array) ? actual.map(&:to_s) : [ actual.to_s ]
        expected.map(&:to_s).any? { |value| actual_values.include?(value) }
      when nil, "any"
        true
      when true, false
        ActiveModel::Type::Boolean.new.cast(actual) == expected
      else
        actual.to_s == expected.to_s
      end
    end

    def normalize_hash(value)
      return {} unless value.is_a?(Hash)

      value.deep_stringify_keys
    end
  end
end
