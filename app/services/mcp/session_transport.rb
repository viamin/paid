# frozen_string_literal: true

module Mcp
  class SessionTransport
    SubscriptionTimeoutError = Class.new(StandardError)

    class Subscriber
      attr_reader :broadcasting, :callback

      def initialize(broadcasting:)
        @broadcasting = broadcasting
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @events = []
        @subscribed = false
        @callback = ->(payload) { push(normalize_payload(payload)) }
      end

      def push(event)
        @mutex.synchronize do
          @events << event
          @condition.signal
        end
      end

      def pop(timeout:)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

        @mutex.synchronize do
          loop do
            event = @events.shift
            return event if event

            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return nil if remaining <= 0

            @condition.wait(@mutex, remaining)
          end
        end
      end

      def mark_subscribed
        @mutex.synchronize do
          @subscribed = true
          @condition.broadcast
        end
      end

      def wait_for_subscription!(timeout: 1)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

        @mutex.synchronize do
          until @subscribed
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise SubscriptionTimeoutError, "Timed out waiting for MCP session subscription" if remaining <= 0

            @condition.wait(@mutex, remaining)
          end
        end
      end

      private

      def normalize_payload(payload)
        decoded =
          case payload
          when String
            JSON.parse(payload)
          else
            payload
          end

        decoded.deep_symbolize_keys
      rescue JSON::ParserError
        payload
      end
    end

    class << self
      def subscribe(session_id:)
        subscriber = Subscriber.new(broadcasting: broadcasting_for(session_id))
        pubsub.subscribe(subscriber.broadcasting, subscriber.callback, -> { subscriber.mark_subscribed })
        subscriber.wait_for_subscription!

        subscriber
      end

      def unsubscribe(session_id: nil, subscriber:)
        pubsub.unsubscribe(subscriber.broadcasting, subscriber.callback)
      end

      def publish(session_id:, event:, data:)
        ActionCable.server.broadcast(
          broadcasting_for(session_id),
          { event: event, data: data }
        )
      end

      private

      def broadcasting_for(session_id)
        "mcp_session:#{session_id}"
      end

      def pubsub
        ActionCable.server.pubsub
      end
    end
  end
end
