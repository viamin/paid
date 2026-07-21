# frozen_string_literal: true

module Runners
  # Provider-neutral registry of subscription auth materializers (RDR-041).
  #
  # A materializer describes how a subscription runner turns an encrypted
  # `RunnerCredential` into container runtime state, and crucially whether that
  # materialization is remote-safe — i.e. whether it can run on a Docker backend
  # where `supports_host_paths? == false` (remote Docker, Swarm).
  #
  # This registry is the seam between RDR-041 (managed auth lifecycle) and
  # RDR-048 (multi-host scheduler/readiness). Host selection asks
  # `remote_safe?` to decide whether a managed credential makes a subscription
  # runner eligible for remote placement; providers without a remote-safe
  # materializer stay local-only until their adapter ships.
  #
  # Today only Claude has a remote-safe managed materializer (env-var injection
  # of `CLAUDE_CODE_OAUTH_TOKEN`, or writing the native `.credentials.json`
  # directly into the container). Gemini and Copilot have remote-safe native
  # config materializers (#2964) that regenerate only the minimal CLI config
  # the provider needs from a managed `RunnerCredential`. Codex still depends
  # on a Docker-host bind mount, so it is NOT remote-safe here. When the Codex
  # remote-safe materializer (#2962) ships, it registers itself as remote-safe
  # and remote placement opens up automatically.
  class SubscriptionAuthMaterializers
    MATERIALIZE_ENV = "env"
    MATERIALIZE_NATIVE_FILE = "native_file"
    MATERIALIZE_HOST_MOUNT = "host_mount"
    MATERIALIZE_UNSUPPORTED = "unsupported"

    ROTATION_NONE = "none"
    ROTATION_SERVER_REFRESH_ONLY = "server_refresh_only"
    ROTATION_CONTAINER_MAY_ROTATE = "container_may_rotate"
    ROTATION_UNSUPPORTED = "unsupported"

    Materializer = Struct.new(
      :runner_key,
      :materialization_mode,
      :rotation_risk,
      :remote_safe,
      keyword_init: true
    ) do
      def remote_safe?
        remote_safe == true
      end

      def requires_host_paths?
        materialization_mode == MATERIALIZE_HOST_MOUNT
      end
    end

    # The canonical provider facts. Keys are runner_keys. Each entry documents
    # the *managed* materializer shape for that provider. Host-forwarded legacy
    # auth is always host-path-bound regardless of this registry; this table
    # only answers whether a managed `RunnerCredential` can carry the run to a
    # host-path-less backend.
    MATERIALIZERS = {
      "claude" => Materializer.new(
        runner_key: "claude",
        materialization_mode: MATERIALIZE_ENV,
        rotation_risk: ROTATION_SERVER_REFRESH_ONLY,
        remote_safe: true
      ),
      "codex" => Materializer.new(
        runner_key: "codex",
        materialization_mode: MATERIALIZE_HOST_MOUNT,
        rotation_risk: ROTATION_CONTAINER_MAY_ROTATE,
        remote_safe: false
      ),
      "gemini" => Materializer.new(
        runner_key: "gemini",
        materialization_mode: MATERIALIZE_NATIVE_FILE,
        rotation_risk: ROTATION_CONTAINER_MAY_ROTATE,
        remote_safe: true
      ),
      "copilot" => Materializer.new(
        runner_key: "copilot",
        materialization_mode: MATERIALIZE_NATIVE_FILE,
        rotation_risk: ROTATION_CONTAINER_MAY_ROTATE,
        remote_safe: true
      )
    }.freeze

    class << self
      def for_runner(runner_key)
        MATERIALIZERS[runner_key.to_s]
      end

      def remote_safe?(runner_key)
        for_runner(runner_key)&.remote_safe? == true
      end

      def registered_runner_keys
        MATERIALIZERS.keys
      end
    end
  end
end
