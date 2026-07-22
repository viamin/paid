# frozen_string_literal: true

module Configuration
  module Profiles
    # Enumerates the curated set of configuration profiles. Profiles are plain
    # Ruby modules added to +ALL+; there is no runtime mutation or injection
    # surface (RDR-044). Lookups by name are case-insensitive on the profile's
    # underscored {Base#name}.
    module Registry
      module_function

      ALL = [
        SoloAutomated,
        TeamReviewed,
        ObserveOnly,
        ManualOnLabel
      ].freeze

      def all
        ALL
      end

      def names
        ALL.map(&:name)
      end

      def find(name)
        normalized = name.to_s
        ALL.find { |profile| profile.name == normalized }
      end

      def fetch(name)
        find(name) || raise(ArgumentError, "Unknown configuration profile: #{name.inspect}")
      end

      def exists?(name)
        !find(name).nil?
      end

      def summaries
        all.map do |profile|
          {
            profile_id: profile.name,
            name: profile.display_name,
            description: profile.description,
            clarifying_questions: profile.clarifying_questions
          }
        end
      end
    end
  end
end
