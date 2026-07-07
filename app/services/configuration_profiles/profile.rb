# frozen_string_literal: true

module ConfigurationProfiles
<<<<<<< HEAD
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
=======
  # Base class for configuration profiles (RDR-044). A profile is a named
  # bundle of recommended changes across one or more levels (:user, :project,
  # :tenant). Subclasses override +id+, +summary+, and +build_plan+ to
  # describe the posture and compute a serialized plan for a target.
  class Profile
    LEVELS = %i[user project tenant].freeze

    class << self
      def id(id = nil)
        @id = id.to_s if id
        @id
      end

      def display_name(name = nil)
        @display_name = name if name
        @display_name || @id&.to_s&.titleize
      end

      def description(text = nil)
        @description = text if text
        @description
      end

      def levels(*values)
        @levels = values.flatten.map(&:to_sym) if values.any?
        @levels || []
      end

      def required_policy_class(klass = nil)
        @required_policy_class = klass if klass
        @required_policy_class
      end

      def build_plan(_user:, _project:, _overrides: {})
        raise NotImplementedError, "#{name} must implement .build_plan"
      end

      def override_keys
        []
      end

      # Read-only accessors for +build_plan+ implementations. Plan building must
      # never create rows (the profile "recommend"/"plan" tools execute no
      # writes), so these return an unsaved default record when none exists yet
      # instead of the persisting `user.settings` / `account.tenant_setting!`
      # helpers used elsewhere in the app.
      def current_user_settings(user)
        user.user_setting || UserSetting.new(user: user)
      end

      def current_tenant_setting(user)
        user.account.tenant_setting || TenantSetting.new(account: user.account)
      end

      def summary
        {
          id: id,
          name: display_name,
          description: description,
          levels: levels
        }
      end
>>>>>>> origin/main
    end
  end
end
