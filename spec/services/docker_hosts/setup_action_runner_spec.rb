# frozen_string_literal: true

require "rails_helper"
require "openssl"

RSpec.describe DockerHosts::SetupActionRunner do
  let(:host) { create(:docker_host, daemon_architecture: "arm64") }

  describe ".call" do
    it "generates and stores encrypted client TLS material" do
      result = described_class.call(
        host: host,
        action: "generate_client_bundle",
        params: ActionController::Parameters.new(client_common_name: "paid-client"),
        key_size: 1024
      )

      expect(result.success?).to be(true)
      expect(host.reload.client_tls_material_present?).to be(true)
      expect(host.client_ca_key_pem).to include("BEGIN RSA PRIVATE KEY")
      expect(host.setup_step("client_tls")).to include("status" => "verified")
      expect(host.read_attribute_before_type_cast("client_private_key_pem")).not_to include("BEGIN PRIVATE KEY")
      expect(host.read_attribute_before_type_cast("client_ca_key_pem")).not_to include("BEGIN PRIVATE KEY")
    end

    it "stores uploaded client TLS material" do
      bundle = build_uploaded_client_bundle

      result = described_class.call(
        host: host,
        action: "upload_client_bundle",
        params: ActionController::Parameters.new(
          client_ca_pem: bundle.fetch(:ca_cert).to_pem,
          client_ca_key_pem: bundle.fetch(:ca_key).to_pem,
          client_certificate_pem: bundle.fetch(:client_cert).to_pem,
          client_private_key_pem: bundle.fetch(:client_key).to_pem
        )
      )

      expect(result.success?).to be(true)
      expect(host.reload.client_certificate_pem).to include("BEGIN CERTIFICATE")
      expect(host.setup_step("client_tls")).to include("status" => "verified")
    end

    it "rejects invalid uploaded client TLS material" do
      result = described_class.call(
        host: host,
        action: "upload_client_bundle",
        params: ActionController::Parameters.new(
          client_ca_pem: "not a cert",
          client_certificate_pem: "not a cert",
          client_private_key_pem: "not a key"
        )
      )

      expect(result.success?).to be(false)
      expect(result.message).to include("Client CA certificate is not a valid PEM certificate")
      expect(host.reload.client_tls_material_present?).to be(false)
      expect(host.setup_step("client_tls")).to include("status" => "failing")
    end

    it "rejects a client certificate that does not chain to the uploaded CA" do
      ca_bundle = build_uploaded_client_bundle
      mismatched_bundle = build_uploaded_client_bundle(
        ca_subject: "/CN=other-ca",
        client_serial: 4,
        ca_serial: 3
      )

      result = described_class.call(
        host: host,
        action: "upload_client_bundle",
        params: ActionController::Parameters.new(
          client_ca_pem: ca_bundle.fetch(:ca_cert).to_pem,
          client_certificate_pem: mismatched_bundle.fetch(:client_cert).to_pem,
          client_private_key_pem: mismatched_bundle.fetch(:client_key).to_pem
        )
      )

      expect(result.success?).to be(false)
      expect(result.message).to eq("Client certificate is not signed by the provided CA certificate.")
      expect(host.reload.client_tls_material_present?).to be(false)
      expect(host.setup_step("client_tls")).to include("status" => "failing")
    end

    it "generates a server CSR when SANs are supplied" do
      result = described_class.call(
        host: host,
        action: "generate_server_material",
        params: ActionController::Parameters.new(
          server_common_name: "docker.example.test",
          server_sans: "docker.example.test,100.113.201.1",
          server_mode: "csr"
        )
      )

      expect(result.success?).to be(true)
      expect(host.reload.server_csr_pem).to include("BEGIN CERTIFICATE REQUEST")
      expect(host.server_private_key_pem).to include("BEGIN RSA PRIVATE KEY")
    end

    it "creates a server certificate signed by the stored client CA" do
      generate_client_bundle
      result = generate_server_material(server_mode: "ca_signed")
      expect(result.success?).to be(true)
      expect_server_certificate_to_chain_to_client_ca
      expect(host.server_csr_pem).to be_nil
    end

    it "fails CA-signed server generation when the client CA private key is unavailable" do
      generate_client_bundle
      host.update!(client_ca_key_pem: nil)

      result = described_class.call(
        host: host,
        action: "generate_server_material",
        params: ActionController::Parameters.new(
          server_common_name: "docker.example.test",
          server_sans: "docker.example.test,100.113.201.1",
          server_mode: "ca_signed"
        )
      )

      expect(result.success?).to be(false)
      expect(result.message).to eq(
        "Stored client CA private key required. Generate a client bundle or upload the CA private key, or use CSR mode."
      )
    end

    it "marks the required network verified when the network exists remotely" do
      seed_client_tls_material
      backend = instance_double(Containers::Backends::RemoteDocker, get_network: true)
      allow(DockerHosts::RemoteBackendSession).to receive(:with_backend).and_yield(backend)

      result = described_class.call(
        host: host,
        action: "verify_network",
        params: ActionController::Parameters.new(required_network_name: "shared-agents")
      )

      expect(result.success?).to be(true)
      expect(backend).to have_received(:get_network).with(NetworkPolicy::NETWORK_NAME)
      expect(host.reload.required_network_status).to eq("ready")
      expect(host.required_network_name).to eq(NetworkPolicy::NETWORK_NAME)
      expect(host.setup_step("required_network")).to include("status" => "verified")
    end

    it "downgrades the required network status when verification fails" do
      seed_client_tls_material
      host.update!(required_network_status: "ready")
      backend = instance_double(Containers::Backends::RemoteDocker)
      allow(backend).to receive(:get_network).and_raise(Docker::Error::NotFoundError, "missing network")
      allow(DockerHosts::RemoteBackendSession).to receive(:with_backend).and_yield(backend)

      result = described_class.call(
        host: host,
        action: "verify_network",
        params: ActionController::Parameters.new(required_network_name: "shared-agents")
      )

      expect(result.success?).to be(false)
      expect(backend).to have_received(:get_network).with(NetworkPolicy::NETWORK_NAME)
      expect(host.reload.required_network_status).to eq("failing")
      expect(host).not_to be_placement_ready
      expect(host.setup_step("required_network")).to include("status" => "failing")
    end

    it "downgrades the required network status when network creation fails" do
      seed_client_tls_material
      host.update!(required_network_status: "ready")
      backend = instance_double(Containers::Backends::RemoteDocker)
      allow(backend).to receive(:create_network).and_raise(Docker::Error::DockerError, "permission denied")
      allow(DockerHosts::RemoteBackendSession).to receive(:with_backend).and_yield(backend)

      result = described_class.call(
        host: host,
        action: "create_network",
        params: ActionController::Parameters.new(
          required_network_name: "shared-agents",
          allow_network_create: "1"
        )
      )

      expect(result.success?).to be(false)
      expect_primary_network_create_call(backend)
      expect(host.reload.required_network_status).to eq("failing")
      expect(host).not_to be_placement_ready
      expect(host.setup_step("required_network")).to include("status" => "failing")
    end

    # @spec CONTAINER-RUNTIME-030
    it "marks the infra network verified when the network exists remotely" do
      seed_client_tls_material
      allow(DockerHosts::RemoteBackendSession).to receive(:with_backend).and_yield(
        instance_double(Containers::Backends::RemoteDocker, get_network: true)
      )

      result = described_class.call(
        host: host,
        action: "verify_infra_network",
        params: ActionController::Parameters.new
      )

      expect(result.success?).to be(true)
      expect(host.reload.required_infra_network_status).to eq("ready")
      expect(host.setup_step("required_infra_network")).to include("status" => "verified")
    end

    # @spec CONTAINER-RUNTIME-030
    it "downgrades the infra network status when verification fails" do
      seed_client_tls_material
      host.update!(required_infra_network_status: "ready")
      allow(DockerHosts::RemoteBackendSession).to receive(:with_backend).and_yield(
        instance_double(Containers::Backends::RemoteDocker).tap do |backend|
          allow(backend).to receive(:get_network).and_raise(Docker::Error::NotFoundError, "missing network")
        end
      )

      result = described_class.call(
        host: host,
        action: "verify_infra_network",
        params: ActionController::Parameters.new
      )

      expect(result.success?).to be(false)
      expect(host.reload.required_infra_network_status).to eq("failing")
      expect(host).not_to be_placement_ready
      expect(host.setup_step("required_infra_network")).to include("status" => "failing")
    end

    # @spec CONTAINER-RUNTIME-030
    it "creates the infra network without an explicit subnet and without touching the primary network" do
      seed_client_tls_material
      backend = instance_double(Containers::Backends::RemoteDocker, create_network: true)
      allow(DockerHosts::RemoteBackendSession).to receive(:with_backend).and_yield(backend)

      result = described_class.call(
        host: host,
        action: "create_infra_network",
        params: ActionController::Parameters.new(allow_network_create: "1")
      )

      expect(result.success?).to be(true)
      expect(backend).to have_received(:create_network).with(NetworkPolicy::INFRA_NETWORK_NAME, { "Driver" => "bridge" })
      expect(host.reload.required_infra_network_status).to eq("ready")
      expect(host.setup_step("required_infra_network")).to include("status" => "verified")
    end

    # @spec CONTAINER-RUNTIME-030
    it "downgrades the infra network status when network creation fails" do
      seed_client_tls_material
      host.update!(required_infra_network_status: "ready")
      allow(DockerHosts::RemoteBackendSession).to receive(:with_backend).and_yield(
        instance_double(Containers::Backends::RemoteDocker).tap do |backend|
          allow(backend).to receive(:create_network).and_raise(Docker::Error::DockerError, "permission denied")
        end
      )

      result = described_class.call(
        host: host,
        action: "create_infra_network",
        params: ActionController::Parameters.new(allow_network_create: "1")
      )

      expect(result.success?).to be(false)
      expect(host.reload.required_infra_network_status).to eq("failing")
      expect(host).not_to be_placement_ready
      expect(host.setup_step("required_infra_network")).to include("status" => "failing")
    end

    # @spec CONTAINER-RUNTIME-030
    it "creates the primary network with the runtime subnet" do
      seed_client_tls_material
      backend = instance_double(Containers::Backends::RemoteDocker, create_network: true)
      allow(DockerHosts::RemoteBackendSession).to receive(:with_backend).and_yield(backend)

      result = described_class.call(
        host: host,
        action: "create_network",
        params: ActionController::Parameters.new(
          required_network_name: NetworkPolicy::NETWORK_NAME,
          allow_network_create: "1"
        )
      )

      expect(result.success?).to be(true)
      expect_primary_network_create_call(backend)
      expect(host.reload.required_network_name).to eq(NetworkPolicy::NETWORK_NAME)
    end

    it "captures daemon architecture and summary during the TLS test" do
      seed_client_tls_material
      host.update!(daemon_architecture: nil, daemon_summary: nil)
      backend = instance_double(
        Containers::Backends::RemoteDocker,
        ping: "OK",
        system_info: { "Architecture" => "aarch64", "ServerVersion" => "27.0.3" }
      )
      allow(DockerHosts::RemoteBackendSession).to receive(:with_backend).and_yield(backend)

      result = described_class.call(
        host: host,
        action: "test_tls",
        params: ActionController::Parameters.new
      )

      expect(result.success?).to be(true)
      host.reload
      expect(host.daemon_architecture).to eq("arm64")
      expect(host.daemon_summary).to eq("Docker 27.0.3")
      expect(host.readiness_status).to eq("ready")
      expect(host.setup_step("tls_connectivity")).to include("status" => "verified")
    end

    it "leaves the daemon summary blank when system_info omits the server version" do
      seed_client_tls_material
      host.update!(daemon_architecture: nil, daemon_summary: nil)
      backend = instance_double(
        Containers::Backends::RemoteDocker,
        ping: "OK",
        system_info: { "Architecture" => "x86_64" }
      )
      allow(DockerHosts::RemoteBackendSession).to receive(:with_backend).and_yield(backend)

      described_class.call(
        host: host,
        action: "test_tls",
        params: ActionController::Parameters.new
      )

      host.reload
      expect(host.daemon_architecture).to eq("amd64")
      expect(host.daemon_summary).to be_nil
    end

    it "fails image inspection when the image architecture does not match the daemon" do
      image = instance_double(Docker::Image, info: { "Architecture" => "amd64", "RepoDigests" => [ "paid-agent@sha256:123" ] })
      backend = instance_double(Containers::Backends::RemoteDocker, get_image: image)
      allow(DockerHosts::RemoteBackendSession).to receive(:with_backend).and_yield(backend)

      result = described_class.call(
        host: host,
        action: "inspect_image",
        params: ActionController::Parameters.new
      )

      expect(result.success?).to be(false)
      expect(result.message).to include("Expected \"arm64\"")
      expect(host.reload.image_status).to eq("failing")
      expect(host.setup_step("image_availability")).to include("status" => "failing")
    end

    it "backfills the daemon architecture during image inspection for a brand-new host" do
      host.update!(daemon_architecture: nil)
      image = instance_double(Docker::Image, info: { "Architecture" => "aarch64", "RepoDigests" => [ "paid-agent@sha256:123" ] })
      backend = instance_double(
        Containers::Backends::RemoteDocker,
        system_info: { "Architecture" => "aarch64", "ServerVersion" => "28.3.1" },
        get_image: image
      )
      allow(DockerHosts::RemoteBackendSession).to receive(:with_backend).and_yield(backend)

      result = described_class.call(
        host: host,
        action: "inspect_image",
        params: ActionController::Parameters.new
      )

      expect(result.success?).to be(true)
      expect(host.reload.daemon_architecture).to eq("arm64")
      expect(host.daemon_summary).to eq("Docker 28.3.1")
      expect(host.image_status).to eq("ready")
      expect(host.setup_step("image_availability")).to include("status" => "verified")
    end

    it "fails image inspection when the image architecture is unavailable" do
      image = instance_double(Docker::Image, info: { "RepoDigests" => [] })
      backend = instance_double(Containers::Backends::RemoteDocker, get_image: image)
      allow(DockerHosts::RemoteBackendSession).to receive(:with_backend).and_yield(backend)

      result = described_class.call(
        host: host,
        action: "inspect_image",
        params: ActionController::Parameters.new
      )

      expect(result.success?).to be(false)
      expect(result.message).to include("did not report an image architecture")
      expect(host.reload.image_status).to eq("missing")
      expect(host.setup_step("image_availability")).to include("status" => "failing")
    end

    it "fails callback reachability when the probe container exits non-zero" do
      container = instance_double(Docker::Container, wait: { "StatusCode" => 7 })
      backend = instance_double(
        Containers::Backends::RemoteDocker,
        create_container: container,
        start_container: true,
        delete_container: true
      )
      allow(DockerHosts::RemoteBackendSession).to receive(:with_backend).and_yield(backend)

      result = described_class.call(
        host: host,
        action: "test_callback",
        params: ActionController::Parameters.new(required_network_name: "shared-agents", callback_url: "https://example.test/callback")
      )

      expect(result.success?).to be(false)
      expect(backend).to have_received(:create_container).with(
        hash_including("NetworkingConfig" => { "EndpointsConfig" => { NetworkPolicy::NETWORK_NAME => {} } })
      )
      expect(result.message).to include("exit status 7")
      expect(host.reload.setup_step("callback_reachability")).to include("status" => "failing")
    end

    it "treats an auto-removed callback probe container as successful cleanup" do
      container = instance_double(Docker::Container, wait: { "StatusCode" => 0 })
      backend = instance_double(
        Containers::Backends::RemoteDocker,
        create_container: container,
        start_container: true
      )
      allow(backend).to receive(:delete_container).with(container, force: true).and_raise(Docker::Error::NotFoundError)
      allow(DockerHosts::RemoteBackendSession).to receive(:with_backend).and_yield(backend)

      result = described_class.call(
        host: host,
        action: "test_callback",
        params: ActionController::Parameters.new(required_network_name: "shared-agents", callback_url: "https://example.test/callback")
      )

      expect(result.success?).to be(true)
      expect(backend).to have_received(:create_container).with(
        hash_including("NetworkingConfig" => { "EndpointsConfig" => { NetworkPolicy::NETWORK_NAME => {} } })
      )
      expect(host.reload.setup_step("callback_reachability")).to include("status" => "verified")
    end

    it "fails the dry run when the disposable container exits non-zero" do
      container = instance_double(Docker::Container, wait: { "StatusCode" => 1 })
      backend = instance_double(
        Containers::Backends::RemoteDocker,
        create_container: container,
        start_container: true,
        delete_container: true
      )
      allow(DockerHosts::RemoteBackendSession).to receive(:with_backend).and_yield(backend)

      result = described_class.call(
        host: host,
        action: "dry_run",
        params: ActionController::Parameters.new(required_network_name: "shared-agents")
      )

      expect(result.success?).to be(false)
      expect(backend).to have_received(:create_container).with(
        hash_including("NetworkingConfig" => { "EndpointsConfig" => { NetworkPolicy::NETWORK_NAME => {} } })
      )
      expect(result.message).to include("exit status 1")
      expect(host.reload.setup_step("dry_run")).to include("status" => "failing")
    end

    it "treats an auto-removed dry-run container as successful cleanup" do
      container = instance_double(Docker::Container, wait: { "StatusCode" => 0 })
      backend = instance_double(
        Containers::Backends::RemoteDocker,
        create_container: container,
        start_container: true
      )
      allow(backend).to receive(:delete_container).with(container, force: true).and_raise(Docker::Error::NotFoundError)
      allow(DockerHosts::RemoteBackendSession).to receive(:with_backend).and_yield(backend)

      result = described_class.call(
        host: host,
        action: "dry_run",
        params: ActionController::Parameters.new(required_network_name: "shared-agents")
      )

      expect(result.success?).to be(true)
      expect(backend).to have_received(:create_container).with(
        hash_including("NetworkingConfig" => { "EndpointsConfig" => { NetworkPolicy::NETWORK_NAME => {} } })
      )
      expect(host.reload.setup_step("dry_run")).to include("status" => "verified")
    end
  end

  def generate_client_bundle
    described_class.call(
      host: host,
      action: "generate_client_bundle",
      params: ActionController::Parameters.new(client_common_name: "paid-client")
    )
  end

  def seed_client_tls_material
    host.update!(
      client_ca_pem: "ca",
      client_certificate_pem: "cert",
      client_private_key_pem: "key"
    )
  end

  def generate_server_material(server_mode:)
    described_class.call(
      host: host,
      action: "generate_server_material",
      params: ActionController::Parameters.new(
        server_common_name: "docker.example.test",
        server_sans: "docker.example.test,100.113.201.1",
        server_mode: server_mode
      )
    )
  end

  def expect_server_certificate_to_chain_to_client_ca
    host.reload
    server_certificate = OpenSSL::X509::Certificate.new(host.server_certificate_pem)
    client_ca = OpenSSL::X509::Certificate.new(host.client_ca_pem)

    expect(server_certificate.to_pem).to include("BEGIN CERTIFICATE")
    expect(server_certificate.issuer.to_s).to eq(client_ca.subject.to_s)
    expect(server_certificate.verify(client_ca.public_key)).to be(true)
  end

  def expect_primary_network_create_call(backend)
    expect(backend).to have_received(:create_network).with(
      NetworkPolicy::NETWORK_NAME,
      { "Driver" => "bridge", "IPAM" => { "Config" => [ { "Subnet" => NetworkPolicy::NETWORK_SUBNET } ] } }
    )
  end

  def build_certificate(...)
    DockerHosts::Certificates.build_certificate(...)
  end

  def build_uploaded_client_bundle(ca_subject: "/CN=paid-upload-ca", ca_serial: 1, client_serial: 2)
    ca_key = OpenSSL::PKey::RSA.new(1024)
    ca_cert = build_certificate(
      subject: ca_subject,
      issuer: nil,
      public_key: ca_key.public_key,
      signing_key: ca_key,
      serial: ca_serial,
      is_ca: true
    )
    client_key = OpenSSL::PKey::RSA.new(1024)
    client_cert = build_certificate(
      subject: "/CN=paid-client",
      issuer: ca_cert,
      public_key: client_key.public_key,
      signing_key: ca_key,
      serial: client_serial,
      is_ca: false,
      extended_key_usage: "clientAuth"
    )

    { ca_key: ca_key, ca_cert: ca_cert, client_key: client_key, client_cert: client_cert }
  end
end
