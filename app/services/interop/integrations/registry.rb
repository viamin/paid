# frozen_string_literal: true

module Interop
  module Integrations
    class Registry
      INTEGRATION_CLASSES = [
        Interop::Integrations::GithubCopilot,
        Interop::Integrations::Cursor,
        Interop::Integrations::Devin,
        Interop::Integrations::Factory,
        Interop::Integrations::InternalAgentWorkflows
      ].freeze

      class << self
        def all
          INTEGRATION_CLASSES
        end

        def find(key)
          all.find { |klass| klass.key == key.to_s }
        end

        def keys
          all.map(&:key)
        end

        def display_names
          all.map { |klass| [ klass.key, klass.display_name ] }.to_h
        end
      end
    end
  end
end
