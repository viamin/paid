# frozen_string_literal: true

module ChatSessions
  # Allocates Paid-owned request context before delegating one API chat request
  # to agent-harness. The persisted sequence makes a restarted delivery a new
  # outbound request rather than an ambiguous replay of a prior provider call.
  class HarnessTransport
    MAX_REQUEST_ATTEMPTS = 1
    # Inactivity bound: the maximum time with no data on the stream.
    READ_DEADLINE = 60.seconds
    # Wall-clock bound on the whole outbound attempt. Independent of, and much
    # longer than, READ_DEADLINE so a model that is still actively streaming
    # past the read deadline's duration is never cancelled mid-stream.
    REQUEST_DEADLINE = 10.minutes
    METADATA_SEQUENCE_KEY = "api_chat_request_sequence"

    def initialize(chat_session:, transport:, clock: Process.method(:clock_gettime))
      @chat_session = chat_session
      @transport = transport
      @clock = clock
    end

    def call(request, &observer)
      @transport.call(request.merge(execution_context), &observer)
    end

    private

    def execution_context
      context = allocate_context
      {
        request_id: context.fetch(:request_id),
        retry: { max_attempts: MAX_REQUEST_ATTEMPTS },
        timeout: { read_seconds: READ_DEADLINE.in_seconds },
        cancellation: DeadlineCancellation.new(deadline: context.fetch(:deadline), clock: @clock),
        metadata: {
          conversation_id: @chat_session.external_id,
          runner_id: @chat_session.runner_id,
          request_sequence: context.fetch(:sequence)
        }.compact
      }
    end

    def allocate_context
      @chat_session.with_lock do
        metadata = @chat_session.metadata.to_h.deep_dup
        sequence = metadata.fetch(METADATA_SEQUENCE_KEY, 0).to_i + 1
        metadata[METADATA_SEQUENCE_KEY] = sequence
        @chat_session.update_column(:metadata, metadata)

        {
          request_id: "chat-#{@chat_session.external_id}-#{sequence}",
          sequence: sequence,
          deadline: monotonic_now + REQUEST_DEADLINE.in_seconds
        }
      end
    end

    def monotonic_now
      @clock.call(Process::CLOCK_MONOTONIC)
    end

    # AgentHarness accepts an object responding to +cancelled?+. A monotonic
    # deadline keeps the request bound independent of wall-clock changes.
    class DeadlineCancellation
      def initialize(deadline:, clock: Process.method(:clock_gettime))
        @deadline = deadline
        @clock = clock
      end

      def cancelled?
        @clock.call(Process::CLOCK_MONOTONIC) >= @deadline
      end
    end
  end
end
