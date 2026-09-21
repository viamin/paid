# frozen_string_literal: true

require "rubygems/version"

module AppleVerificationWorkers
  # Parsed Xcode version constraint such as ">= 26.0, < 27.0" or "~> 26.0".
  # Carries exactly the containment check worker-profile binding needs: a
  # profile's advertised Xcode range satisfies a repository's declared
  # constraint only when every version the profile may run also satisfies the
  # declaration, so a constraint mismatch fails at sync time with a
  # deterministic diagnostic instead of surfacing at run time.
  # @spec APPLE-WORKER-013
  class VersionRequirement
    Bound = Data.define(:version, :exclusive)

    SEGMENT_PATTERN = /\A(>=|<=|>|<|=|~>)?\s*(\d+(?:\.\d+)*)\z/

    attr_reader :source, :lower, :upper

    class << self
      def parse(constraint)
        bounds = { lower: nil, upper: nil }
        segments = constraint.to_s.split(",")
        raise ArgumentError, "constraint is empty" if segments.empty?

        segments.each { |segment| fold_bounds!(bounds, segment) }
        ensure_non_empty!(bounds)

        new(source: constraint.to_s, **bounds)
      rescue ArgumentError => e
        raise InvalidVersionConstraint, "#{constraint.inspect} is not a valid version constraint: #{e.message}"
      end

      private

      def fold_bounds!(bounds, segment)
        match = segment.strip.match(SEGMENT_PATTERN)
        raise ArgumentError, "unsupported segment #{segment.strip.inspect}" unless match

        operator, version = match[1] || "=", Gem::Version.new(match[2])
        bounds_for(operator, version).each { |side, bound| bounds[side] = tighter(side, bounds[side], bound) }
      end

      def bounds_for(operator, version)
        case operator
        when ">=" then [ [ :lower, Bound.new(version:, exclusive: false) ] ]
        when ">" then [ [ :lower, Bound.new(version:, exclusive: true) ] ]
        when "<=" then [ [ :upper, Bound.new(version:, exclusive: false) ] ]
        when "<" then [ [ :upper, Bound.new(version:, exclusive: true) ] ]
        when "=" then [ [ :lower, Bound.new(version:, exclusive: false) ], [ :upper, Bound.new(version:, exclusive: false) ] ]
        when "~>" then [ [ :lower, Bound.new(version:, exclusive: false) ], [ :upper, Bound.new(version: version.bump, exclusive: true) ] ]
        end
      end

      def tighter(side, current, candidate)
        return candidate unless current

        comparison = candidate.version <=> current.version
        return candidate if (side == :lower ? comparison.positive? : comparison.negative?)
        return current unless comparison.zero?

        candidate.exclusive ? candidate : current
      end

      def ensure_non_empty!(bounds)
        lower, upper = bounds.values_at(:lower, :upper)
        return unless lower && upper

        point_empty = lower.version == upper.version && (lower.exclusive || upper.exclusive)
        raise ArgumentError, "constraint matches no version" if lower.version > upper.version || point_empty
      end
    end

    def initialize(source:, lower:, upper:)
      @source = source
      @lower = lower
      @upper = upper
    end

    def within?(other)
      lower_within?(other.lower) && upper_within?(other.upper)
    end

    def to_s
      source
    end

    private

    def lower_within?(declared)
      return true unless declared
      return false if lower.nil?

      comparison = lower.version <=> declared.version
      comparison.positive? || (comparison.zero? && !(declared.exclusive && !lower.exclusive))
    end

    def upper_within?(declared)
      return true unless declared
      return false if upper.nil?

      comparison = upper.version <=> declared.version
      comparison.negative? || (comparison.zero? && !(declared.exclusive && !upper.exclusive))
    end
  end
end
