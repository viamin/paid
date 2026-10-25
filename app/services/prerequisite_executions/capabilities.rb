# frozen_string_literal: true

module PrerequisiteExecutions
  # Read-only capability inspection for a prerequisite evidence validation.
  #
  # Answers "can Paid's execution infrastructure run this validation right
  # now, and if not, which exact authorized action changes that?" from the
  # provisioner's own placement interfaces — never from probing the
  # control plane's local Docker socket, because availability in an
  # investigation workspace and availability in Paid's execution
  # infrastructure are different facts.
  #
  # @spec PREREQ-EXEC-001 @spec PREREQ-EXEC-002 @spec PREREQ-EXEC-003
  # @spec PREREQ-EXEC-004 @spec PREREQ-EXEC-005
  class Capabilities
    Requirement = Data.define(:kind, :message, :authorized_action) do
      def to_h
        { "kind" => kind, "message" => message, "authorized_action" => authorized_action }
      end
    end

    HostCapability = Data.define(:identifier, :backend_type, :placement_ready, :readiness_status,
      :image_status, :required_network_status, :required_infra_network_status, :remediation_hint) do
      def to_h
        {
          "identifier" => identifier,
          "backend_type" => backend_type,
          "placement_ready" => placement_ready,
          "readiness_status" => readiness_status,
          "image_status" => image_status,
          "required_network_status" => required_network_status,
          "required_infra_network_status" => required_infra_network_status,
          "remediation_hint" => remediation_hint
        }
      end
    end

    Report = Data.define(:hosts, :tool_flag_enabled, :tool_image, :image_allowed, :missing) do
      # @spec PREREQ-EXEC-001
      def environment_available?
        hosts.any?(&:placement_ready)
      end

      # @spec PREREQ-EXEC-005
      def ready?
        environment_available? && missing.empty?
      end

      def compatible_host_identifiers
        hosts.select(&:placement_ready).map(&:identifier)
      end

      def to_h
        {
          "environment_available" => environment_available?,
          "compatible_hosts" => compatible_host_identifiers,
          "tool_flag_enabled" => tool_flag_enabled,
          "tool_image" => tool_image,
          "image_allowed" => image_allowed,
          "missing" => missing.map(&:to_h)
        }
      end
    end

    TOOL_FLAG = :marketplace_tool_sidecars
    TOOL_FLAG_ENABLE_ACTION =
      "Ask an account admin to enable the marketplace_tool_sidecars feature flag for this tenant " \
      "(Settings → Features) before provisioning tool sidecars."
    IMAGE_ALLOWLIST_ACTION =
      "Ask an account admin to add %<image>s to their allowed service images list " \
      "(user settings → allowed service images) for this account."
    HOST_SETUP_ACTION =
      "Add or enable a Docker host (Settings → Docker hosts) so Paid can provision isolated runs " \
      "on a placement-ready backend."
    HOST_READINESS_ACTION =
      "Restore readiness on Docker host %<identifier>s (failing: %<failing>s), or add another host."

    def self.call(...)
      new(...).call
    end

    def initialize(project:, tool_image: nil)
      @project = project
      @tool_image = tool_image.presence
    end

    def call
      Report.new(
        hosts: host_capabilities,
        tool_flag_enabled: tool_flag_enabled?,
        tool_image: tool_image,
        image_allowed: image_allowed?,
        missing: missing_requirements
      )
    end

    private

    attr_reader :project, :tool_image

    def host_capabilities
      project.account.docker_hosts.enabled.ordered.map do |host|
        HostCapability.new(
          identifier: host.identifier,
          backend_type: host.backend_type,
          placement_ready: host.placement_ready?,
          readiness_status: host.readiness_status,
          image_status: host.image_status,
          required_network_status: host.required_network_status,
          required_infra_network_status: host.required_infra_network_status,
          remediation_hint: host.placement_ready? ? nil : host_remediation_hint(host)
        )
      end
    end

    def host_remediation_hint(host)
      format(HOST_READINESS_ACTION,
        identifier: host.identifier,
        failing: host_failing_signals(host).presence || "unknown")
    end

    def host_failing_signals(host)
      signals = []
      signals << "readiness=#{host.readiness_status}" unless host.ready?
      signals << "image=#{host.image_status}" unless host.image_status == "ready"
      signals << "network=#{host.required_network_status}" unless host.required_network_status == "ready"
      signals << "infra_network=#{host.required_infra_network_status}" unless host.required_infra_network_status == "ready"
      host.failing_check.presence && signals << "check=#{host.failing_check}"
      signals
    end

    def tool_flag_enabled?
      FeatureFlags.enabled?(TOOL_FLAG, project: project)
    end

    def image_allowed?
      return true if tool_image.blank?

      Containers::McpProvisioner.account_allowed_images_for(project: project).include?(tool_image)
    end

    # Each missing requirement carries the exact authorized human action;
    # this service never enables flags, edits allowlists, or mutates hosts.
    # @spec PREREQ-EXEC-002 @spec PREREQ-EXEC-003 @spec PREREQ-EXEC-004
    def missing_requirements
      requirements = []
      if host_capabilities.empty?
        requirements << no_backend_requirement
      elsif placement_ready_hosts.empty?
        requirements.concat(unready_host_requirements)
      end
      requirements << tool_flag_requirement if tool_image.present? && !tool_flag_enabled?
      requirements << image_allowlist_requirement if tool_image.present? && tool_flag_enabled? && !image_allowed?
      requirements
    end

    def no_backend_requirement
      Requirement.new(
        kind: "host_capability",
        message: "No enabled Docker host is configured for this account, so Paid cannot provision an isolated run.",
        authorized_action: HOST_SETUP_ACTION
      )
    end

    def unready_host_requirements
      host_capabilities.reject(&:placement_ready).map do |host|
        Requirement.new(
          kind: "host_capability",
          message: "Docker host #{host.identifier} (#{host.backend_type}) is not placement-ready for agent runs.",
          authorized_action: host.remediation_hint
        )
      end
    end

    def tool_flag_requirement
      Requirement.new(
        kind: "tool_flag",
        message: "The marketplace_tool_sidecars feature flag is off for this tenant, so tool sidecars will not provision.",
        authorized_action: TOOL_FLAG_ENABLE_ACTION
      )
    end

    def image_allowlist_requirement
      Requirement.new(
        kind: "image_allowlist",
        message: "Tool image #{tool_image} is not in this account's allowed service images list.",
        authorized_action: format(IMAGE_ALLOWLIST_ACTION, image: tool_image)
      )
    end

    def placement_ready_hosts
      host_capabilities.select(&:placement_ready)
    end
  end
end
