# frozen_string_literal: true

module Interop
  module Integrations
    class Base
      class << self
        def key
          raise NotImplementedError, "#{name} must implement .key"
        end

        def display_name
          raise NotImplementedError, "#{name} must implement .display_name"
        end

        def description
          raise NotImplementedError, "#{name} must implement .description"
        end

        def ingestion_protocol
          raise NotImplementedError, "#{name} must implement .ingestion_protocol"
        end

        def supported_features
          raise NotImplementedError, "#{name} must implement .supported_features"
        end

        def agent_type_key
          raise NotImplementedError, "#{name} must implement .agent_type_key"
        end

        def normalize_external_metadata(raw_metadata)
          raise NotImplementedError, "#{name} must implement .normalize_external_metadata"
        end
      end
    end
  end
end
