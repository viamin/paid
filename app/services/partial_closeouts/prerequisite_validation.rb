# frozen_string_literal: true

module PartialCloseouts
  # Runs the narrow live-environment proof required before a maintenance
  # adapter may rely on native analyzers or a marketplace tool sidecar. It is
  # intentionally a consumer of runner/provisioner contracts: it neither
  # exposes a host shell nor adds a host-mounted sidecar variant.
  # @spec PARTIAL-CLOSEOUT-030
  class PrerequisiteValidation
    NATIVE_ANALYZER_COMMAND = "ruby -e 'puts RUBY_DESCRIPTION'"
    SIDECAR_PROBE_COMMAND = "ruby -rnet/http -ruri -e 'url = URI(ENV.fetch(\"PAID_TOOL_SIDECAR_ENDPOINT\")); response = Net::HTTP.get_response(url); puts \"HTTP \#{response.code}\"; exit(response.is_a?(Net::HTTPSuccess) ? 0 : 1)'"
    Result = Data.define(:status, :evidence)

    def self.call(...) = new(...).call

    def initialize(agent_run:, host_readiness: Containers::HostReadiness, feature_flags: FeatureFlags)
      @agent_run = agent_run
      @host_readiness = host_readiness
      @feature_flags = feature_flags
    end

    def call
      preflight = preflight_result
      return persist(**preflight) unless preflight[:status] == "ready"

      execute_validation(preflight)
    end

    private

    attr_reader :agent_run, :feature_flags, :host_readiness

    def preflight_result
      return unavailable("tool_authorization_required", "Attach an allowlisted marketplace tool before requesting this validation.") if Array(agent_run.tool_sidecar_snapshot).blank?
      return unavailable("tool_rollout_authorization_required", "Enable marketplace tool sidecars for this project through its authorized rollout setting; this action does not enable flags.") unless feature_flags.enabled?(:marketplace_tool_sidecars, project: agent_run.project)

      readiness = host_readiness.call(force_refresh: true)
      compatible = readiness.values.find { |host| host[:healthy] }
      return unavailable("compatible_execution_backend_unavailable", "Register or repair a compatible isolated execution backend; the control-plane Docker socket is not execution evidence.", readiness:) unless compatible

      { status: "ready", readiness: readiness, selected_host: compatible[:host] }
    end

    def execute_validation(preflight)
      evidence = preflight.slice(:readiness, :selected_host)
      agent_run.provision_execution_environment
      return persist(status: "partial", evidence: evidence.merge(
        code: "tool_endpoint_unavailable",
        setup_action: "Inspect the allowlisted tool sidecar provisioning result and retry only after it exposes a healthy endpoint."
      )) if tool_definition["url"].blank?

      native = execution_artifact("native_analyzer", NATIVE_ANALYZER_COMMAND)
      sidecar = execution_artifact("tool_sidecar", SIDECAR_PROBE_COMMAND, endpoint_env)
      evidence.merge!(native_analyzer: native, tool_sidecar: sidecar,
        image: Containers::Provision::DEFAULTS[:image], checkout: agent_run.base_commit_sha,
        tool: tool_definition.slice("name", "hostname", "port", "url"))
      persist(status: native[:success] && sidecar[:success] ? "successful" : "failed", evidence: evidence)
    rescue Containers::McpProvisioner::Error => error
      persist(status: "unavailable", evidence: evidence.to_h.merge(
        code: "tool_image_or_provisioning_denied",
        setup_action: "Allowlist the selected tool image or correct its authorized sidecar configuration before retrying.",
        error: error.message
      ))
    rescue Containers::Provision::Error => error
      persist(status: "partial", evidence: evidence.to_h.merge(error: error.message))
    ensure
      cleanup_evidence = cleanup
      merge_cleanup_evidence(cleanup_evidence) if cleanup_evidence
    end

    def execution_artifact(name, command, env = {})
      result = agent_run.execute_in_execution_environment(command, timeout: 60, stream: false, env: env)
      { name: name, stdout: result[:stdout].to_s.truncate(10_000), stderr: result[:stderr].to_s.truncate(10_000), exit_code: result[:exit_code], success: result.success? }
    rescue Containers::Provision::ExecutionError => error
      { name: name, stdout: error.stdout.to_s.truncate(10_000), stderr: error.stderr.to_s.truncate(10_000), exit_code: error.exit_code, success: false }
    end

    def endpoint_env
      { "PAID_TOOL_SIDECAR_ENDPOINT" => tool_definition.fetch("url") }
    end

    def tool_definition
      @tool_definition ||= Array(agent_run.reload.tool_sidecar_endpoints).first || {}
    end

    def unavailable(code, action, readiness: nil)
      { status: "unavailable", evidence: { code: code, setup_action: action, host_readiness: readiness } }
    end

    def persist(status:, evidence:)
      payload = evidence.merge(status: status, recorded_at: Time.current.iso8601)
      agent_run.update!(reconciliation: agent_run.reconciliation.merge("technical_prerequisite_validation" => payload))
      Result.new(status:, evidence: payload)
    end

    def cleanup
      agent_run.cleanup_execution_environment
      { attempted: true, succeeded: true }
    rescue Containers::Provision::Error => error
      { attempted: true, succeeded: false, error: error.message }
    end

    def merge_cleanup_evidence(cleanup_evidence)
      validation = agent_run.reload.reconciliation.fetch("technical_prerequisite_validation", {})
      status = validation["status"] == "successful" && !cleanup_evidence[:succeeded] ? "partial" : validation["status"]
      agent_run.update!(reconciliation: agent_run.reconciliation.merge(
        "technical_prerequisite_validation" => validation.merge("status" => status, "cleanup" => cleanup_evidence)
      ))
    end
  end
end
