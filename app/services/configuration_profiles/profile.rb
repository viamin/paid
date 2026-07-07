# frozen_string_literal: true

module ConfigurationProfiles
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
    end
  end
end
