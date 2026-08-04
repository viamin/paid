# frozen_string_literal: true

module Paid
  @temporal_mutex = Mutex.new
  @temporal_worker_mutex = Mutex.new

  class << self
    # @spec TEMPORAL-ORCHESTRATION-001
    # Returns a connected Temporal client. Connection is established lazily
    # on first call, not during Rails initialization. Thread-safe via Mutex
    # to prevent duplicate connections under concurrent Puma workers.
    #
    # The heavy temporalio gem (139 MB, native Rust extensions) is only
    # required when this method is first called, removing it from the
    # critical boot path.
    #
    # @return [Temporalio::Client] Connected Temporal client
    # @raise [Temporalio::Error] When connection fails
    def temporal_client
      @temporal_mutex.synchronize do
        unless defined?(@temporal_client)
          suppress_circular_require_warnings { require "temporalio/client" }
          @temporal_client = Temporalio::Client.connect(
            temporal_address,
            temporal_namespace
          )
        end
        @temporal_client
      end
    end

    def temporal_worker_client
      @temporal_worker_mutex.synchronize do
        unless defined?(@temporal_worker_client)
          suppress_circular_require_warnings do
            require "temporalio/client"
            require "temporalio/contrib/open_telemetry"
          end

          @temporal_worker_client = Temporalio::Client.connect(
            temporal_address,
            temporal_namespace,
            runtime: TemporalObservability.worker_runtime,
            interceptors: TemporalObservability.client_interceptors
          )
        end

        @temporal_worker_client
      end
    end

    # Resets the cached Temporal client, allowing reconnection on next access.
    # Useful for recovering from connection failures or configuration changes.
    # Also clears the memoized TemporalObservability runtime/tracer caches so
    # that env-driven configuration (metrics exporter, Prometheus bind address,
    # OTLP endpoint) is re-read on the next worker client connection.
    def reset_temporal_client!
      @temporal_mutex.synchronize do
        remove_instance_variable(:@temporal_client) if defined?(@temporal_client)
      end

      @temporal_worker_mutex.synchronize do
        remove_instance_variable(:@temporal_worker_client) if defined?(@temporal_worker_client)
        TemporalObservability.reset!
      end
    end

    # Supports both TEMPORAL_ADDRESS (used in docker-compose services) and
    # TEMPORAL_HOST (used in .env.example / app container config).
    def temporal_address
      ENV["TEMPORAL_ADDRESS"] || ENV.fetch("TEMPORAL_HOST", "localhost:7233")
    end

    def temporal_namespace
      ENV.fetch("TEMPORAL_NAMESPACE", "default")
    end

    def temporal_ui_url
      ENV.fetch("TEMPORAL_UI_URL", "http://localhost:8080").sub(%r{/+\z}, "")
    end

    # @spec TEMPORAL-ORCHESTRATION-001
    # Dedicated task queue for GitHubPollWorkflow instances.
    # Isolates poll activities from agent-execution workloads so that
    # long-running agent runs cannot starve time-sensitive poll cycles.
    def poll_task_queue
      ENV.fetch("TEMPORAL_POLL_TASK_QUEUE", "paid-poll-tasks")
    end

    # @spec TEMPORAL-ORCHESTRATION-001
    # Dedicated task queue for AgentExecutionWorkflow and related workflows.
    # Keeps agent workloads on their own activity pool, independent of polling.
    def agent_task_queue
      ENV.fetch("TEMPORAL_AGENT_TASK_QUEUE", "paid-agent-tasks")
    end

    private

    def suppress_circular_require_warnings
      original_verbose = $VERBOSE
      $VERBOSE = nil
      yield
    ensure
      $VERBOSE = original_verbose
    end
  end

  # Resolved at load time so workflow code can reference it as a constant
  # without breaking Temporal's deterministic replay requirement.
  AGENT_TASK_QUEUE = agent_task_queue
end
