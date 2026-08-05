# frozen_string_literal: true

require "json"
require "time"

module Paid
  class JsonLogFormatter < Logger::Formatter
    def call(severity, timestamp, _progname, message) # @spec OBSERVABILITY-004
      payload = base_payload(severity, timestamp).merge(normalize_message(message))
      JSON.generate(payload) << "\n"
    end

    private

    def base_payload(severity, timestamp)
      payload = {
        timestamp: timestamp.utc.iso8601(3),
        level: severity.downcase
      }

      request_id = Current.request_id if defined?(Current)
      payload[:request_id] = request_id if request_id.present?

      tags = normalized_tags
      return payload if tags.empty?

      payload[:tags] = tags
      payload
    end

    def normalize_message(message)
      case message
      when Hash
        stringify_keys(message)
      when Exception
        {
          message: message.message,
          error_class: message.class.name
        }
      else
        { message: msg2str(message).strip }
      end
    end

    def normalized_tags
      return [] unless respond_to?(:current_tags)

      Array(current_tags).filter_map do |tag|
        value = tag.to_s.strip
        value unless value.empty?
      end
    end

    def stringify_keys(hash)
      hash.each_with_object({}) do |(key, value), payload|
        payload[key.to_s] = value
      end
    end
  end
end
