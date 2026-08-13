# frozen_string_literal: true

module Interop
  module Connectors
    class Registry
      CONNECTOR_CLASSES = [
        Interop::Connectors::Jira,
        Interop::Connectors::Linear,
        Interop::Connectors::GitLab,
        Interop::Connectors::Bitbucket,
        Interop::Connectors::Slack,
        Interop::Connectors::Teams,
        Interop::Connectors::CiSystems
      ].freeze

      class << self
        def all
          CONNECTOR_CLASSES
        end

        def find(key)
          all.find { |klass| klass.key == key.to_s }
        end

        def keys
          all.map(&:key)
        end
      end
    end
  end
end
