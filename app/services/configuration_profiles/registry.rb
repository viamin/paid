# frozen_string_literal: true

module ConfigurationProfiles
  # Central registry of named configuration profiles. A profile bundles
  # cross-cutting changes (user, project, tenant) into a single recommended
  # posture a user can apply with one confirmation. See RDR-044.
  class Registry
    class << self
      def profiles
        @profiles ||= []
      end

      def register(profile)
        profiles << profile unless profiles.include?(profile)
      end

      def reset!
        @profiles = []
      end

      def find(id)
        id = id.to_s
        profiles.find { |profile| profile.id.to_s == id }
      end

      def all
        profiles
      end

      def summaries
        profiles.map(&:summary)
      end
    end
  end
end
