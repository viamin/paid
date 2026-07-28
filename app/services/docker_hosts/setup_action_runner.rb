# frozen_string_literal: true

require "json"
require "shellwords"

module DockerHosts
  class SetupActionRunner
    Result = Struct.new(:success?, :message, :server_private_key_pem, keyword_init: true)

    def self.call(host:, action:, params:)
      new(host:, action:, params:).call
    end

    def initialize(host:, action:, params:)
      @host = host
      @action = action.to_s
      @params = params
    end

    def call
      case action
      when "generate_client_bundle" then generate_client_bundle
      when "upload_client_bundle" then upload_client_bundle
      when "generate_server_material" then generate_server_material
      when "mark_manual_step" then mark_manual_step
      when "test_tls" then test_tls
      when "verify_network" then verify_network
      when "create_network" then create_network
      when "inspect_image" then inspect_image
      when "test_callback" then test_callback
      when "dry_run" then dry_run
      else
        Result.new(success?: false, message: "Unsupported setup helper action.")
      end
    rescue ArgumentError, OpenSSL::OpenSSLError, Docker::Error::DockerError => e
      record_step_failure(step_key_for(action), e.message)
      Result.new(success?: false, message: e.message)
    end

    private

    attr_reader :host, :action, :params

    def generate_client_bundle
      ca_key = OpenSSL::PKey::RSA.new(4096)
      ca_cert = Certificates.build_certificate(
        subject: "/CN=#{host.identifier}-paid-remote-docker-ca",
        issuer: nil,
        public_key: ca_key.public_key,
        signing_key: ca_key,
        serial: 1,
        is_ca: true
      )

      client_key = OpenSSL::PKey::RSA.new(4096)
      client_cert = Certificates.build_certificate(
        subject: "/CN=#{params[:client_common_name].presence || "#{host.identifier}-paid-client"}",
        issuer: ca_cert,
        public_key: client_key.public_key,
        signing_key: ca_key,
        serial: 2,
        is_ca: false,
        extended_key_usage: "clientAuth"
      )

      host.assign_attributes(
        client_ca_pem: ca_cert.to_pem,
        client_ca_key_pem: ca_key.to_pem,
        client_certificate_pem: client_cert.to_pem,
        client_private_key_pem: client_key.to_pem
      )
      record_step_success("client_tls", "Client TLS bundle generated and stored encrypted.")
      host.save!

      Result.new(success?: true, message: "Generated and stored client TLS material for #{host.display_name}.")
    end

    def upload_client_bundle
      host.assign_attributes(
        client_ca_pem: required_param!(:client_ca_pem),
        client_ca_key_pem: optional_param(:client_ca_key_pem),
        client_certificate_pem: required_param!(:client_certificate_pem),
        client_private_key_pem: required_param!(:client_private_key_pem)
      )
      record_step_success("client_tls", "Uploaded client TLS bundle stored encrypted.")
      host.save!

      Result.new(success?: true, message: "Uploaded client TLS material for #{host.display_name}.")
    end

    def generate_server_material
      common_name = required_param!(:server_common_name)
      san_entries = Certificates.san_entries(params[:server_sans])
      raise ArgumentError, "Supply at least one SAN for server certificate generation" if san_entries.empty?

      return generate_server_csr(common_name:, san_entries:) if params[:server_mode] == "csr"

      generate_server_certificate(common_name:, san_entries:)
    end

    def mark_manual_step
      step_key = required_param!(:step_key)
      record_step_success(step_key, "Operator marked this manual step complete.", completed: true)
      host.save!
      Result.new(success?: true, message: "Marked #{step_key.humanize.downcase} complete.")
    end

    def test_tls
      DockerHosts::RemoteBackendSession.with_backend(host) do |backend|
        response = backend.ping
        host.last_checked_at = Time.current
        host.last_ready_at = Time.current
        host.readiness_status = "ready"
        host.failing_check = nil
        host.last_error = nil
        record_step_success("tls_connectivity", "Docker daemon responded to TLS ping: #{response.inspect}")
      end
      host.save!

      Result.new(success?: true, message: "TLS connectivity verified for #{host.display_name}.")
    end

    def verify_network
      network_name = host.required_network_name.presence || required_param!(:required_network_name)
      host.required_network_name = network_name

      DockerHosts::RemoteBackendSession.with_backend(host) do |backend|
        backend.get_network(network_name)
        host.required_network_status = "ready"
        record_step_success("required_network", "Verified Docker network #{network_name.inspect}.")
      end
      host.save!

      Result.new(success?: true, message: "Verified Docker network #{network_name}.")
    end

    def create_network
      raise ArgumentError, "Authorize network creation before running this helper" unless ActiveModel::Type::Boolean.new.cast(params[:allow_network_create])

      network_name = host.required_network_name.presence || required_param!(:required_network_name)
      host.required_network_name = network_name

      DockerHosts::RemoteBackendSession.with_backend(host) do |backend|
        backend.create_network(network_name, { "Driver" => "bridge" })
        host.required_network_status = "ready"
        record_step_success("required_network", "Created Docker network #{network_name.inspect}.")
      end
      host.save!

      Result.new(success?: true, message: "Created Docker network #{network_name}.")
    end

    def inspect_image
      DockerHosts::RemoteBackendSession.with_backend(host) do |backend|
        image = backend.get_image(host.image_tag)
        info = image.info
        architecture = info["Architecture"].presence || info.dig("Os", "Architecture").presence
        if architecture.present? && architecture == host.daemon_architecture
          host.image_status = "ready"
          record_step_success(
            "image_availability",
            "Image #{host.image_tag.inspect} present. Architecture: #{architecture}. Digests: #{Array(info['RepoDigests']).join(', ').presence || 'none'}."
          )
        else
          host.image_status = architecture.present? ? "failing" : "missing"
          raise Docker::Error::DockerError, image_architecture_failure_message(architecture:, info:)
        end
      end
      host.save!

      Result.new(success?: true, message: "Inspected #{host.image_tag} on #{host.display_name}.")
    end

    def test_callback
      network_name = host.required_network_name.presence || required_param!(:required_network_name)
      url = host.callback_url.presence || required_param!(:callback_url)
      command = [ "sh", "-lc", "wget -qO- #{Shellwords.escape(url)} >/dev/null || curl -fsSL #{Shellwords.escape(url)} >/dev/null" ]

      DockerHosts::RemoteBackendSession.with_backend(host) do |backend|
        container = backend.create_container(
          "Image" => host.image_tag,
          "Cmd" => command,
          "HostConfig" => { "AutoRemove" => true },
          "NetworkingConfig" => { "EndpointsConfig" => { network_name => {} } }
        )
        backend.start_container(container)
        ensure_successful_container_exit!(container, step_key: "callback_reachability", failure_prefix: "Disposable container could not reach #{url}")
        record_step_success("callback_reachability", "Disposable container reached #{url}.")
      ensure
        cleanup_probe_container(backend, container)
      end
      host.save!

      Result.new(success?: true, message: "Verified callback reachability from a disposable container.")
    end

    def dry_run
      network_name = host.required_network_name.presence || required_param!(:required_network_name)

      DockerHosts::RemoteBackendSession.with_backend(host) do |backend|
        container = backend.create_container(
          "Image" => host.image_tag,
          "Cmd" => [ "true" ],
          "HostConfig" => { "AutoRemove" => true },
          "NetworkingConfig" => { "EndpointsConfig" => { network_name => {} } }
        )
        backend.start_container(container)
        ensure_successful_container_exit!(container, step_key: "dry_run", failure_prefix: "Disposable container dry run failed on #{network_name}")
        record_step_success("dry_run", "Created, started, and cleaned up a disposable container on #{network_name}.")
      ensure
        cleanup_probe_container(backend, container)
      end
      host.save!

      Result.new(success?: true, message: "Dry-run provisioning succeeded for #{host.display_name}.")
    end

    def step_key_for(name)
      {
        "generate_client_bundle" => "client_tls",
        "upload_client_bundle" => "client_tls",
        "generate_server_material" => "server_certificate_install",
        "test_tls" => "tls_connectivity",
        "verify_network" => "required_network",
        "create_network" => "required_network",
        "inspect_image" => "image_availability",
        "test_callback" => "callback_reachability",
        "dry_run" => "dry_run"
      }.fetch(name.to_s, name.to_s)
    end

    def required_param!(key)
      value = params[key].to_s.strip
      raise ArgumentError, "#{key.to_s.humanize} can't be blank" if value.blank?

      value
    end

    def optional_param(key)
      params[key].to_s.strip.presence
    end

    def ensure_successful_container_exit!(container, step_key:, failure_prefix:)
      status_code = container.wait(15).fetch("StatusCode", nil)
      return if status_code.to_i.zero?

      raise Docker::Error::DockerError, "#{failure_prefix} (exit status #{status_code || 'unknown'})."
    rescue KeyError
      raise Docker::Error::DockerError, "#{failure_prefix} (missing exit status)."
    end

    def cleanup_probe_container(backend, container)
      return unless container

      backend.delete_container(container, force: true)
    rescue Docker::Error::NotFoundError
      nil
    end

    def image_architecture_failure_message(architecture:, info:)
      base_message = "Image #{host.image_tag.inspect} present. Architecture: #{architecture || 'unknown'}. Digests: #{Array(info['RepoDigests']).join(', ').presence || 'none'}."
      return "#{base_message} Docker did not report an image architecture." if architecture.blank?

      "#{base_message} Expected #{host.daemon_architecture.inspect} for host compatibility."
    end

    def record_step_success(step_key, message, completed: false)
      write_step(step_key, status: "verified", message: message, completed: completed)
    end

    def record_step_failure(step_key, message)
      write_step(step_key, status: "failing", message: message, completed: false)
      host.last_checked_at = Time.current
      host.readiness_status = "failing" if step_key == "tls_connectivity"
      host.failing_check = step_key if step_key == "tls_connectivity"
      host.last_error = message if step_key == "tls_connectivity"
      host.save! if host.persisted? && host.changed?
    rescue ActiveRecord::ActiveRecordError
      nil
    end

    def write_step(step_key, status:, message:, completed:)
      setup = host.metadata.deep_dup
      setup["setup"] ||= {}
      setup["setup"]["steps"] ||= {}
      setup["setup"]["steps"][step_key] = {
        "status" => status,
        "message" => message,
        "completed" => completed,
        "checked_at" => Time.current.iso8601
      }
      host.metadata = setup
    end

    def generate_server_certificate(common_name:, san_entries:)
      ca_cert = OpenSSL::X509::Certificate.new(stored_client_ca_pem!)
      ca_key = OpenSSL::PKey.read(stored_client_ca_key_pem!)
      server_key = OpenSSL::PKey::RSA.new(4096)
      server_cert = Certificates.build_certificate(
        subject: "/CN=#{common_name}",
        issuer: ca_cert,
        public_key: server_key.public_key,
        signing_key: ca_key,
        serial: SecureRandom.random_number(2**128),
        is_ca: false,
        san_entries: san_entries,
        extended_key_usage: "serverAuth"
      )

      host.assign_attributes(
        server_certificate_pem: server_cert.to_pem,
        server_private_key_pem: server_key.to_pem,
        server_csr_pem: nil
      )
      record_step_success("server_certificate_install", "Generated a server certificate signed by the stored client CA.")
      host.save!

      Result.new(
        success?: true,
        message: "Generated a server certificate signed by the stored client CA for #{host.display_name}.",
        server_private_key_pem: server_key.to_pem
      )
    end

    def generate_server_csr(common_name:, san_entries:)
      server_key = OpenSSL::PKey::RSA.new(4096)
      csr = Certificates.build_certificate_request(
        subject: "/CN=#{common_name}",
        private_key: server_key,
        san_entries: san_entries
      )

      host.assign_attributes(
        server_private_key_pem: server_key.to_pem,
        server_csr_pem: csr.to_pem,
        server_certificate_pem: nil
      )
      record_step_success("server_certificate_install", "Generated a server private key and CSR with SANs for manual CA signing.")
      host.save!

      Result.new(
        success?: true,
        message: "Generated a server CSR for #{host.display_name}.",
        server_private_key_pem: server_key.to_pem
      )
    end

    def stored_client_ca_pem!
      host.client_ca_pem.presence || raise(ArgumentError, "Generate or upload a client CA before generating a server certificate.")
    end

    def stored_client_ca_key_pem!
      host.client_ca_key_pem.presence || raise(
        ArgumentError,
        "Stored client CA private key required. Generate a client bundle or upload the CA private key, or use CSR mode."
      )
    end
  end
end
