# frozen_string_literal: true

module Prerequisites
  # Reads the current execution-host capabilities and tool/authorization
  # policy for a project through existing runner/provisioner interfaces.
  #
  # This is inspection only: it never provisions, never mutates flags or
  # allowlists, and never treats a missing local Docker socket as "no usable
  # execution environment" — each configured backend is reported through its
  # own Containers::HostReadiness probe result (#4643).
  # @spec PREREQ-EVIDENCE-001 @spec PREREQ-EVIDENCE-004
  class CapabilityReport
    FLAG_ENABLE_ACTION = "Enable the marketplace_tool_sidecars feature for this tenant " \
      "(tenant_settings.features) — an account admin action; the validation never enables it itself."
    TOOL_ENTRY_MISSING_ACTION = "Publish or import an active marketplace entry of entry_type \"tool\" " \
      "for this account so a sidecar interaction can be validated."
    NO_HEALTHY_HOST_CHECK = "execution_host"

    Report = Data.define(
      :hosts,
      :healthy_host_identifiers,
      :compatible_host,
      :tool_sidecars_enabled,
      :tool_sidecar_authorized_action,
      :allowlisted_images,
      :tool_entry,
      :tool_image,
      :tool_image_allowed,
      :tool_image_authorized_action,
      :host_blockers,
      :checked_at,
      :scope_digest
    ) do
      def compatible_host? = compatible_host.present?
      def tool_sidecars_enabled? = tool_sidecars_enabled == true
      def tool_image_allowed? = tool_image_allowed == true
      def tool_available? = tool_sidecars_enabled? && tool_entry.present? && tool_image_allowed?

      def to_h
        {
          hosts: hosts,
          healthy_host_identifiers: healthy_host_identifiers,
          compatible_host: compatible_host,
          tool_sidecars_enabled: tool_sidecars_enabled,
          tool_sidecar_authorized_action: tool_sidecar_authorized_action,
          allowlisted_images: allowlisted_images,
          tool_entry: tool_entry,
          tool_image: tool_image,
          tool_image_allowed: tool_image_allowed,
          tool_image_authorized_action: tool_image_authorized_action,
          host_blockers: host_blockers,
          checked_at: checked_at,
          scope_digest: scope_digest
        }
      end
    end

    def self.call(...) = new(...).call

    # Digest of the current policy inputs (flag state, allowlist, selected
    # tool entry) without probing hosts — used to flag stale terminal
    # validation evidence cheaply (PREREQ-EVIDENCE-007).
    def self.scope_digest_for(project:)
      report = new(project:)
      report.send(:compute_scope_digest, report.selected_tool_entry)
    end

    def initialize(project:, host_readiness: Containers::HostReadiness)
      @project = project
      @host_readiness = host_readiness
    end

    # The tool entry a validation would select. Public so StartValidation can
    # snapshot the same selection the executor will use without re-implementing
    # the preference for an allowlisted entry.
    def selected_tool_entry
      entries = project.account.marketplace_entries
        .active.with_entry_type("tool").ordered.includes(:current_version).to_a
      entries.find { |entry| allowlisted_images.include?(tool_entry_image(entry).to_s) } || entries.first
    end

    def tool_entry_image(entry)
      return nil unless entry

      entry.current_version&.canonical_artifact.to_h["image"].presence
    end

    # @spec PREREQ-EVIDENCE-001
    def call
      hosts = host_readiness.call
      healthy = hosts.select { |_host, payload| payload[:healthy] }.keys
      tool_entry = selected_tool_entry
      tool_image = tool_entry_image(tool_entry)

      Report.new(
        hosts: hosts,
        healthy_host_identifiers: healthy,
        compatible_host: healthy.first,
        tool_sidecars_enabled: tool_sidecars_enabled?,
        tool_sidecar_authorized_action: tool_sidecars_enabled? ? nil : FLAG_ENABLE_ACTION,
        allowlisted_images: allowlisted_images,
        tool_entry: entry_identity(tool_entry),
        tool_image: tool_image,
        tool_image_allowed: tool_image.present? && allowlisted_images.include?(tool_image),
        tool_image_authorized_action: tool_image_authorized_action(tool_entry, tool_image),
        host_blockers: host_blockers(hosts),
        checked_at: Time.current,
        scope_digest: compute_scope_digest(tool_entry)
      )
    end

    private

    attr_reader :host_readiness, :project

    def host_blockers(hosts)
      hosts.filter_map do |host, payload|
        next if payload[:healthy]

        {
          "check" => NO_HEALTHY_HOST_CHECK,
          "reason" => "Execution host #{host} is not ready: #{payload[:failing_check]} — #{payload[:remediation_hint]}",
          "authorized_action" => payload[:remediation_hint]
        }
      end
    end

    def tool_sidecars_enabled?
      FeatureFlags.enabled?(:marketplace_tool_sidecars, project: project)
    end

    def allowlisted_images
      @allowlisted_images ||= Containers::McpProvisioner.allowed_images_for_project(project).sort
    end

    def entry_identity(entry)
      return nil unless entry

      {
        "id" => entry.id,
        "name" => entry.name,
        "version" => entry.current_version&.version,
        "version_id" => entry.current_version&.id
      }
    end

    def tool_image_authorized_action(entry, image)
      return TOOL_ENTRY_MISSING_ACTION if entry.nil?
      return nil if image.present? && allowlisted_images.include?(image)

      "Add #{image.presence || "the tool entry's image"} to this account's allowed service images " \
        "(an admin/owner user-settings action) or publish a tool entry whose image is allowlisted."
    end

    # Digest of the policy inputs a validation's evidence is scoped to. Cheap,
    # Docker-free reads only: flag state, allowlist, selected tool entry, so
    # the Inbox pane can flag stale terminal evidence without probing hosts
    # (PREREQ-EVIDENCE-007).
    def compute_scope_digest(tool_entry)
      inputs = [
        "flag=#{tool_sidecars_enabled?}",
        "allowlist=#{allowlisted_images.join(",")}",
        "tool=#{entry_identity(tool_entry).to_json}"
      ].join("|")
      Digest::SHA256.hexdigest(inputs)
    end
  end
end
