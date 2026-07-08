# frozen_string_literal: true

module ConfigurationProfiles
  # A named operating-mode preset: a human label plus a target value for every
  # field in {FieldSet}. Construction enforces full field coverage so a profile
  # can never silently go stale when a new operating-mode flag is added — the
  # drift regression guard in the spec suite is the durable version of this
  # check.
  class Profile < Data.define(:key, :name, :description, :values)
    def initialize(key:, name:, description:, values:)
      values = values.deep_stringify_keys
      validate_coverage!(key, values)
      super
    end

    def value_for(field_key)
      values.fetch(field_key.to_s)
    end

    # Difference between this profile's targets and a snapshot (field => value)
    # of a project's current settings. Returns an array of {Change} ordered by
    # {FieldSet} declaration order. Empty when the snapshot already matches.
    def diff_against(snapshot)
      FieldSet.keys.filter_map do |key|
        current = snapshot[key.to_s]
        target = values[key.to_s]
        next if FieldSet.equivalent?(current, target)

        Change.new(field: key, from: current, to: target)
      end
    end

    def matches?(snapshot)
      diff_against(snapshot).empty?
    end

    def to_s = name

    private

    def validate_coverage!(key, values)
      expected = FieldSet.keys.map(&:to_s)
      missing = expected - values.keys
      extra = values.keys - expected
      return if missing.empty? && extra.empty?

      raise ArgumentError, <<~MSG.squish
        Profile #{key.inspect} does not cover the operating-mode field set.
        Missing fields: #{missing.join(', ').presence || 'none'}.
        Unknown fields: #{extra.join(', ').presence || 'none'}.
        Add the missing fields to the profile (or declare them in
        ConfigurationProfiles::FieldSet).
      MSG
    end
  end
end
