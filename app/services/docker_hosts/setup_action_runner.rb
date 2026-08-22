# frozen_string_literal: true

require "json"
require "shellwords"

module DockerHosts
  class SetupActionRunner
    DEFAULT_KEY_SIZE = 4096
    Result = Struct.new(:success?, :message, :server_private_key_pem, keyword_init: true)

    def self.call(host:, action:, params:, key_size: DEFAULT_KEY_SIZE)
      new(host:, action:, params:, key_size:).call
    end

    def initialize(host:, action:, params:, key_size: DEFAULT_KEY_SIZE)
      @host = host
      @action = action.to_s
      @params = params
      @key_size = key_size
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
      when "verify_infra_network" then verify_infra_network
      when "create_infra_network" then create_infra_network
      when "inspect_image" then inspect_image
      when "test_callback" then test_callback
      when "dry_run" then dry_run
      else
        Result.new(success?: false, message: "Unsupported setup helper action.")
      end
    rescue ArgumentError, OpenSSL::OpenSSLError, Docker::Error::DockerError => e
      downgrade_status_for_failure(step_key_for(action))
      record_step_failure(step_key_for(action), e.message)
      Result.new(success?: false, message: e.message)
    end

    private

    attr_reader :host, :action, :params, :key_size

    # Generates an RSA keypair at the configured size. Production uses the
    # 4096-bit default; specs override via the +key_size:+ kwarg to avoid the
    # ~1s cost of a 4096-bit key when the assertions don't depend on key size.
    def generate_rsa_key
      OpenSSL::PKey::RSA.new(key_size)
    end

    def generate_client_bundle
      ca_key = generate_rsa_key
      ca_cert = Certificates.build_certificate(
        subject: "/CN=#{host.identifier}-paid-remote-docker-ca",
        issuer: nil,
        public_key: ca_key.public_key,
        signing_key: ca_key,
        serial: 1,
        is_ca: true
      )

      client_key = generate_rsa_key
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
      client_ca_pem = required_param!(:client_ca_pem)
      client_ca_key_pem = optional_param(:client_ca_key_pem)
      client_certificate_pem = required_param!(:client_certificate_pem)
      client_private_key_pem = required_param!(:client_private_key_pem)

      validate_uploaded_client_tls_bundle!(
        client_ca_pem: client_ca_pem,
        client_ca_key_pem: client_ca_key_pem,
        client_certificate_pem: client_certificate_pem,
        client_private_key_pem: client_private_key_pem
      )

      host.assign_attributes(
        client_ca_pem: client_ca_pem,
        client_ca_key_pem: client_ca_key_pem,
        client_certificate_pem: client_certificate_pem,
        client_private_key_pem: client_private_key_pem
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
        info = capture_daemon_details(backend)
        host.last_checked_at = Time.current
        host.last_ready_at = Time.current
        host.readiness_status = "ready"
        host.failing_check = nil
        host.last_error = nil
        record_step_success(
          "tls_connectivity",
          "Docker daemon responded to TLS ping: #{response.inspect}. " \
            "Architecture: #{host.daemon_architecture.presence || 'unknown'}. " \
            "Version: #{info['ServerVersion'].presence || 'unknown'}."
        )
      end
      host.save!

      Result.new(success?: true, message: "TLS connectivity verified for #{host.display_name}.")
    end

    def verify_network
      network_name = primary_network_name

      DockerHosts::RemoteBackendSession.with_backend(host) do |backend|
        backend.get_network(network_name)
        host.required_network_name = network_name
        host.required_network_status = "ready"
        record_step_success("required_network", "Verified Docker network #{network_name.inspect}.")
      end
      host.save!

      Result.new(success?: true, message: "Verified Docker network #{network_name}.")
    end

    def create_network
      raise ArgumentError, "Authorize network creation before running this helper" unless ActiveModel::Type::Boolean.new.cast(params[:allow_network_create])

      network_name = primary_network_name

      DockerHosts::RemoteBackendSession.with_backend(host) do |backend|
        backend.create_network(network_name, docker_network_create_config(network_name))
        host.required_network_name = network_name
        host.required_network_status = "ready"
        record_step_success("required_network", "Created Docker network #{network_name.inspect}.")
      end
      host.save!

      Result.new(success?: true, message: "Created Docker network #{network_name}.")
    end

    # @spec CONTAINER-RUNTIME-030
    def verify_infra_network
      network_name = NetworkPolicy::INFRA_NETWORK_NAME

      DockerHosts::RemoteBackendSession.with_backend(host) do |backend|
        backend.get_network(network_name)
        host.required_infra_network_status = "ready"
        record_step_success("required_infra_network", "Verified Docker network #{network_name.inspect}.")
      end
      host.save!

      Result.new(success?: true, message: "Verified Docker network #{network_name}.")
    end

    # @spec CONTAINER-RUNTIME-030
    def create_infra_network
      raise ArgumentError, "Authorize network creation before running this helper" unless ActiveModel::Type::Boolean.new.cast(params[:allow_network_create])

      network_name = NetworkPolicy::INFRA_NETWORK_NAME

      DockerHosts::RemoteBackendSession.with_backend(host) do |backend|
        backend.create_network(network_name, docker_network_create_config(network_name))
        host.required_infra_network_status = "ready"
        record_step_success("required_infra_network", "Created Docker network #{network_name.inspect}.")
      end
      host.save!

      Result.new(success?: true, message: "Created Docker network #{network_name}.")
    end

    # Mirrors the bridge driver NetworkPolicy.create_network uses for the
    # local backend (RDR-054, RDR-062). The fixed NETWORK_SUBNET only applies
    # to +paid_agent+ itself; +paid_internal+ has no canonical subnet
    # constant, so Docker is left to auto-assign one (see
    # docs/guides/remote-docker-setup.md, which documents a distinct example
    # subnet per network to avoid collisions on the same daemon). The
    # production-only Internal/no-masquerade options are intentionally
    # omitted here: remote proxy-mode containers must reach
    # PAID_PROXY_EXTERNAL_URL on the Paid control plane, and a
    # Docker-internal bridge network blocks that callback (issue #3545).
    def docker_network_create_config(network_name)
      config = { "Driver" => "bridge" }
      config["IPAM"] = { "Config" => [ { "Subnet" => NetworkPolicy::NETWORK_SUBNET } ] } if network_name == NetworkPolicy::NETWORK_NAME
      config
    end

    def inspect_image
      DockerHosts::RemoteBackendSession.with_backend(host) do |backend|
        capture_daemon_details(backend) if host.daemon_architecture.blank?
        image = backend.get_image(host.image_tag)
        info = image.info
        architecture = normalize_architecture(info["Architecture"].presence || info.dig("Os", "Architecture").presence)
        if architecture_matches_daemon?(architecture)
          host.image_status = "ready"
          record_step_success(
            "image_availability",
            "Image #{host.image_tag.inspect} present. Architecture: #{architecture || 'unknown'}. Digests: #{Array(info['RepoDigests']).join(', ').presence || 'none'}."
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
      network_name = primary_network_name
      url = host.callback_url.presence || required_param!(:callback_url)
      command = [ "sh", "-lc", "wget -qO- #{Shellwords.escape(url)} >/dev/null || curl -fsSL #{Shellwords.escape(url)} >/dev/null" ]

      DockerHosts::RemoteBackendSession.with_backend(host) do |backend|
        host.required_network_name = network_name
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
      network_name = primary_network_name

      DockerHosts::RemoteBackendSession.with_backend(host) do |backend|
        host.required_network_name = network_name
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
        "verify_infra_network" => "required_infra_network",
        "create_infra_network" => "required_infra_network",
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

    def primary_network_name
      NetworkPolicy::NETWORK_NAME
    end

    def validate_uploaded_client_tls_bundle!(client_ca_pem:, client_ca_key_pem:, client_certificate_pem:, client_private_key_pem:)
      ca_certificate = parse_certificate!(client_ca_pem, "Client CA certificate")
      client_certificate = parse_certificate!(client_certificate_pem, "Client certificate")
      client_private_key = parse_private_key!(client_private_key_pem, "Client private key")

      verify_ca_certificate!(ca_certificate)
      verify_matching_key_pair!(certificate: client_certificate, private_key: client_private_key, label: "Client certificate")
      verify_certificate_signed_by_ca!(certificate: client_certificate, ca_certificate: ca_certificate, label: "Client certificate")

      return if client_ca_key_pem.blank?

      ca_private_key = parse_private_key!(client_ca_key_pem, "Client CA private key")
      verify_matching_key_pair!(certificate: ca_certificate, private_key: ca_private_key, label: "Client CA certificate")
    end

    def parse_certificate!(pem, label)
      OpenSSL::X509::Certificate.new(pem)
    rescue OpenSSL::OpenSSLError => e
      raise ArgumentError, "#{label} is not a valid PEM certificate: #{e.message}"
    end

    def parse_private_key!(pem, label)
      OpenSSL::PKey.read(pem)
    rescue OpenSSL::OpenSSLError => e
      raise ArgumentError, "#{label} is not a valid PEM private key: #{e.message}"
    end

    def verify_ca_certificate!(certificate)
      basic_constraints = certificate.extensions.find { |extension| extension.oid == "basicConstraints" }&.value.to_s
      return if basic_constraints.include?("CA:TRUE")

      raise ArgumentError, "Client CA certificate must be a CA certificate."
    end

    def verify_matching_key_pair!(certificate:, private_key:, label:)
      return if certificate.check_private_key(private_key)

      raise ArgumentError, "#{label} does not match the provided private key."
    rescue OpenSSL::OpenSSLError => e
      raise ArgumentError, "#{label} does not match the provided private key: #{e.message}"
    end

    def verify_certificate_signed_by_ca!(certificate:, ca_certificate:, label:)
      return if certificate.issuer.to_s == ca_certificate.subject.to_s && certificate.verify(ca_certificate.public_key)

      raise ArgumentError, "#{label} is not signed by the provided CA certificate."
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

    def capture_daemon_details(backend)
      info = backend.system_info
      host.daemon_architecture = normalize_architecture(info["Architecture"])
      host.daemon_summary = build_daemon_summary(info["ServerVersion"])
      info
    end

    def architecture_matches_daemon?(architecture)
      return false if architecture.blank? || host.daemon_architecture.blank?

      architecture == host.daemon_architecture
    end

    def normalize_architecture(value)
      value.to_s.downcase.strip.presence&.yield_self do |architecture|
        case architecture
        when "x86_64" then "amd64"
        when "aarch64" then "arm64"
        else architecture
        end
      end
    end

    def build_daemon_summary(version)
      return nil if version.blank?

      "Docker #{version}"
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

    def downgrade_status_for_failure(step_key)
      host.required_network_status = "failing" if step_key == "required_network"
      host.required_infra_network_status = "failing" if step_key == "required_infra_network"
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
      server_key = generate_rsa_key
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
      server_key = generate_rsa_key
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
