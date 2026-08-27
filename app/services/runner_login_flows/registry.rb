# frozen_string_literal: true

module RunnerLoginFlows
  # Provider-neutral login-flow registry for runner subscription auth.
  #
  # The current implementation keeps the existing Claude/Codex flow engines and
  # routes new runner targets (omp/opencode) through those same engines by
  # parameterizing the target runner key. This preserves the current login
  # mechanisms while giving the UI a single source of truth for which flows are
  # available for which runner.
  class Registry
    Flow = Struct.new(
      :runner_key,
      :flow_key,
      :session_kind,
      :upstream,
      :title,
      :summary,
      :credential_name,
      :manage_service_key,
      keyword_init: true
    ) do
      def claude_session?
        session_kind == "claude"
      end

      def codex_session?
        session_kind == "codex"
      end

      def route_params(return_to: nil)
        params = { target_runner_key: runner_key }
        params[:return_to] = return_to if return_to.present?
        params
      end
    end

    REGISTRY = {
      "claude" => [
        Flow.new(
          runner_key: "claude",
          flow_key: "browser_capture",
          session_kind: "claude",
          upstream: "anthropic_subscription",
          title: "Claude Browser Login",
          summary: "Capture a managed Claude subscription credential via the official browser-completed CLI flow.",
          credential_name: "Claude Browser Login",
          manage_service_key: "claude"
        )
      ],
      "codex" => [
        Flow.new(
          runner_key: "codex",
          flow_key: "openai_device_code",
          session_kind: "codex",
          upstream: "openai_subscription",
          title: "Connect Codex",
          summary: "Start an OpenAI device-code login and capture the resulting managed Codex credential.",
          credential_name: "Codex Connect Login",
          manage_service_key: "codex"
        )
      ],
      "omp" => [
        Flow.new(
          runner_key: "omp",
          flow_key: "browser_capture",
          session_kind: "claude",
          upstream: "anthropic_subscription",
          title: "Connect Oh My Pi to Claude",
          summary: "Capture a Claude subscription credential and store it for the Oh My Pi runner.",
          credential_name: "Oh My Pi Claude Login",
          manage_service_key: "omp"
        )
      ],
      "opencode" => [
        Flow.new(
          runner_key: "opencode",
          flow_key: "openai_device_code",
          session_kind: "codex",
          upstream: "openai_subscription",
          title: "Connect OpenCode to Codex",
          summary: "Start an OpenAI device-code login and store the resulting credential for the OpenCode runner.",
          credential_name: "OpenCode Connect Login",
          manage_service_key: "opencode"
        )
      ]
    }.freeze

    class << self
      def flows_for(runner_key)
        REGISTRY.fetch(runner_key.to_s, [])
      end

      def fetch(runner_key:, flow_key:)
        flows_for(runner_key).find { |flow| flow.flow_key == flow_key.to_s }
      end

      def flow_for_session(session_kind:, runner_key:)
        flows_for(runner_key).find { |flow| flow.session_kind == session_kind.to_s }
      end

      def runner_keys
        REGISTRY.keys
      end

      def all_flows
        REGISTRY.values.flatten
      end

      def supported_target_runner_key(session_kind:, candidate:, fallback:)
        target = candidate.to_s.presence || fallback.to_s
        return fallback.to_s unless flows_for(target).any? { |flow| flow.session_kind == session_kind.to_s }

        target
      end
    end
  end
end
