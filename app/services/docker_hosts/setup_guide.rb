# frozen_string_literal: true

require "shellwords"
require "uri"

module DockerHosts
  class SetupGuide
    PROFILES = {
      "generic_linux" => "Generic remote Linux",
      "qnap_nas" => "QNAP / NAS"
    }.freeze

    STEPS = [
      { key: "identity", label: "Host name and stable identifier", mode: "verified" },
      { key: "endpoint", label: "Docker host and TLS port", mode: "verified" },
      { key: "client_tls", label: "Client certificate generation or upload", mode: "automated" },
      { key: "server_certificate_install", label: "Server certificate installation", mode: "manual" },
      { key: "tls_connectivity", label: "Docker TLS connectivity test", mode: "verified" },
      { key: "callback_configuration", label: "Paid callback / proxy URL configuration", mode: "verified" },
      { key: "callback_reachability", label: "Callback reachability test from a disposable container", mode: "verified" },
      { key: "required_network", label: "Required network verification or creation", mode: "automated" },
      { key: "image_availability", label: "Image verification and architecture compatibility", mode: "verified" },
      { key: "image_distribution", label: "Image build / pull / load / copy instructions", mode: "manual" },
      { key: "concurrency_limit", label: "Host concurrency limit", mode: "verified" },
      { key: "dry_run", label: "Dry-run disposable container provision and cleanup", mode: "verified" }
    ].freeze

    def initialize(host)
      @host = host
    end

    def profile
      host.setup_profile
    end

    def profile_label
      PROFILES.fetch(profile, PROFILES.fetch("generic_linux"))
    end

    def step_rows
      STEPS.map do |definition|
        definition.merge(
          status: status_for(definition.fetch(:key)),
          detail: detail_for(definition.fetch(:key))
        )
      end
    end

    def manual_instructions
      base = [
        "Paid cannot automate Docker installation, firewall or router changes, VPN or Tailscale routing, or remote file copy unless you already provide remote access.",
        "Subscription-auth or registry credentials still need to be distributed to the remote environment through your existing secret management path."
      ]

      if profile == "qnap_nas"
        base.unshift(
          "Use the QNAP Container Station or Docker package UI to enable TCP/TLS, install the generated server certificate, and verify the exposed port.",
          "QNAP-specific admin UI, certificate trust, and NAS firewall settings remain operator-managed manual work."
        )
      else
        base.unshift(
          "On generic Linux hosts, update the Docker daemon TLS settings, systemd unit or daemon.json, and host firewall rules manually.",
          "Remote certificate copy and daemon restarts stay manual unless you already manage the host out-of-band."
        )
      end

      base
    end

    def command_snippets
      endpoint_host = endpoint_host_for(host.endpoint)
      network_name = host.required_network_name.presence || "paid-agents"
      image_tag = host.image_tag
      tarball_name = image_archive_filename(image_tag)
      remote_tarball_path = "/tmp/#{tarball_name}"
      remote_load_command = Shellwords.join([ "sh", "-lc", "gunzip -c #{Shellwords.escape(remote_tarball_path)} | docker load" ])
      remote_pull_command = Shellwords.join([ "docker", "pull", image_tag ])
      remote_build_command = Shellwords.join([ "docker", "build", "-t", image_tag, "/path/to/paid-agent-context" ])

      {
        "docker_save_load" => [
          "#{Shellwords.join([ "docker", "save", image_tag ])} | gzip > #{Shellwords.escape(tarball_name)}",
          Shellwords.join([ "scp", tarball_name, "#{endpoint_host}:/tmp/" ]),
          Shellwords.join([ "ssh", endpoint_host, remote_load_command ])
        ].join("\n"),
        "registry_pull" => [
          Shellwords.join([ "docker", "pull", image_tag ]),
          Shellwords.join([ "ssh", endpoint_host, remote_pull_command ])
        ].join("\n"),
        "remote_build" => [
          Shellwords.join([ "docker", "build", "-t", image_tag, "." ]),
          Shellwords.join([ "ssh", endpoint_host, remote_build_command ])
        ].join("\n"),
        "network_create" => "#{docker_tls_command_prefix} network create #{Shellwords.escape(network_name)}",
        "server_files" => "Install the generated server certificate and private key on #{endpoint_host}.\nConfigure the Docker daemon to trust the generated CA and restart Docker after the files are in place."
      }
    end

    private

    attr_reader :host

    def status_for(step_key)
      case step_key
      when "identity"
        present?(host.display_name) && present?(host.identifier) ? "verified" : "pending"
      when "endpoint"
        present?(host.endpoint) ? "verified" : "pending"
      when "client_tls"
        host.client_tls_material_present? ? "verified" : "pending"
      when "server_certificate_install"
        manual_step_complete?(step_key) ? "verified" : "manual_required"
      when "tls_connectivity"
        check_status_for(step_key)
      when "callback_configuration"
        present?(host.callback_url) ? "verified" : "pending"
      when "callback_reachability"
        check_status_for(step_key)
      when "required_network"
        return "verified" if host.required_network_status == "ready"
        return "pending" if host.required_network_name.blank?

        check_status_for(step_key)
      when "image_availability"
        return "verified" if host.image_status == "ready"

        check_status_for(step_key)
      when "image_distribution"
        manual_step_complete?(step_key) || host.image_status == "ready" ? "verified" : "manual_required"
      when "concurrency_limit"
        host.manual_concurrency_limit.to_i.positive? ? "verified" : "pending"
      when "dry_run"
        check_status_for(step_key)
      else
        "pending"
      end
    end

    def check_status_for(step_key)
      step = host.setup_step(step_key)
      step.fetch("status", "pending")
    end

    def detail_for(step_key)
      case step_key
      when "identity"
        "#{host.display_name} (#{host.identifier})"
      when "endpoint"
        host.endpoint_label
      when "client_tls"
        return "Client CA, certificate, and private key stored encrypted." if host.client_tls_material_present?

        "Generate a local CA/client bundle or paste uploaded PEM material."
      when "server_certificate_install"
        return "Operator confirmed the server certificate is installed on the remote daemon." if manual_step_complete?(step_key)

        "Paid can generate server cert material, but installation remains manual."
      when "callback_configuration"
        host.callback_url.presence || "Set the callback URL Paid containers must reach."
      when "required_network"
        host.required_network_name.presence || "Choose the Docker network disposable containers should join."
      when "image_availability"
        host.setup_step(step_key).fetch("message", host.image_tag)
      else
        host.setup_step(step_key).fetch("message", nil)
      end
    end

    def manual_step_complete?(step_key)
      host.setup_step(step_key).fetch("completed", false)
    end

    def present?(value)
      value.to_s.present?
    end

    def endpoint_host_for(endpoint)
      URI.parse(endpoint.to_s).host.presence || "remote-host"
    rescue URI::InvalidURIError
      "remote-host"
    end

    def docker_tls_command_prefix
      Shellwords.join([
        "docker",
        "--host", host.endpoint,
        "--tlscacert", "client-ca.pem",
        "--tlscert", "client-cert.pem",
        "--tlskey", "client-key.pem",
        "--tlsverify"
      ])
    end

    def image_archive_filename(image_tag)
      "#{image_tag.to_s.tr(":", "_").gsub(/[^A-Za-z0-9._-]+/, "_")}.tar.gz"
    end
  end
end
