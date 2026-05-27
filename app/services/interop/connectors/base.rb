# frozen_string_literal: true

module Interop
  module Connectors
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

        def event_types
          raise NotImplementedError, "#{name} must implement .event_types"
        end

        def normalize_event(payload)
          raise NotImplementedError, "#{name} must implement .normalize_event"
        end

        def verify_signature?(raw_body, signature:, secret:, request_headers: {})
          raise NotImplementedError, "#{name} must implement .verify_signature?"
        end
      end
    end
  end
end
