# frozen_string_literal: true

module Mcp
  class SessionTransport
    class Subscriber
      def initialize
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @events = []
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
    end

    class << self
      def subscribe(session_id:)
        subscriber = Subscriber.new

        mutex.synchronize do
          subscribers[session_id] << subscriber
        end

        subscriber
      end

      def unsubscribe(session_id:, subscriber:)
        mutex.synchronize do
          session_subscribers = subscribers[session_id]
          session_subscribers.delete(subscriber)
          subscribers.delete(session_id) if session_subscribers.empty?
        end
      end

      def publish(session_id:, event:, data:)
        session_subscribers = mutex.synchronize { subscribers[session_id].dup }
        session_subscribers.each { |subscriber| subscriber.push(event: event, data: data) }
      end

      private

      def subscribers
        @subscribers ||= Hash.new { |hash, key| hash[key] = [] }
      end

      def mutex
        @mutex ||= Mutex.new
      end
    end
  end
end
