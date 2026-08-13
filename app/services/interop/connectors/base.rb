# frozen_string_literal: true

module Interop
  module Connectors
    class Base
      SIGNATURE_TIMESTAMP_TOLERANCE = 5.minutes.to_i

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

        private

        def header_value(request_headers, header_name)
          request_headers.each do |key, value|
            return value if key.to_s.casecmp?(header_name)
          end

          nil
        end

        def recent_unix_timestamp?(timestamp)
          parsed_timestamp = Integer(timestamp, exception: false)
          return false unless parsed_timestamp

          (Time.current.to_i - parsed_timestamp).abs <= SIGNATURE_TIMESTAMP_TOLERANCE
        end
      end
    end
  end
end
