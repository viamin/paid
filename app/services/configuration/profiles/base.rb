# frozen_string_literal: true

module Configuration
  module Profiles
    # Shared interface for profile modules. A profile is a code-curated,
    # immutable-at-runtime description of a desired resolved configuration
    # state (see RDR-044). It declares three things:
    #
    # +targets+::              Hash of setting key => desired value.
    # +clarifying_questions+:: Bounded set of override questions; their +id+s
    #                          are the only override keys {Planner} accepts.
    # +prerequisites_for+::    Unmet conditions that block {Applier} (e.g. the
    #                          Paid review bot GitHub App must be configured).
    module Base
      def self.included(base)
        base.extend(ClassMethods)
      end

      # Default module methods; profiles override the ones they specialize.
      module ClassMethods
        def name
          @name ||= to_s.demodulize.underscore
        end

        def display_name
          @display_name ||= to_s.demodulize.titleize
        end

        def targets
          raise NotImplementedError, "#{name} must declare its targets"
        end

        def clarifying_questions
          []
        end

        # Override keys this profile accepts. Derived from declared
        # clarifying-question ids — profiles never accept arbitrary setting keys.
        def override_keys
          clarifying_questions.map { |question| question[:id].to_s }
        end

        # Returns an array of human-readable unmet prerequisites. An empty
        # array means the profile may be applied. +targets+ is the
        # override-merged effective target set, so prerequisites can depend on
        # answers the caller supplied (e.g. an owner reviewer login).
        def prerequisites_for(_project, targets:)
          []
        end
      end
    end
  end
end
