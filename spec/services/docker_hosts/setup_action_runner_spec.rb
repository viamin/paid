# frozen_string_literal: true

require "rails_helper"

RSpec.describe DockerHosts::SetupActionRunner do
  let(:host) { create(:docker_host, daemon_architecture: "arm64") }

  describe ".call" do
    it "generates and stores encrypted client TLS material" do
      result = described_class.call(
        host: host,
        action: "generate_client_bundle",
        params: ActionController::Parameters.new(client_common_name: "paid-client")
      )

      expect(result.success?).to be(true)
      expect(host.reload.client_tls_material_present?).to be(true)
      expect(host.setup_step("client_tls")).to include("status" => "verified")
      expect(host.read_attribute_before_type_cast("client_private_key_pem")).not_to include("BEGIN PRIVATE KEY")
    end

    it "stores uploaded client TLS material" do
      result = described_class.call(
        host: host,
        action: "upload_client_bundle",
        params: ActionController::Parameters.new(
          client_ca_pem: "-----BEGIN CERTIFICATE-----\nca\n-----END CERTIFICATE-----",
          client_certificate_pem: "-----BEGIN CERTIFICATE-----\nclient\n-----END CERTIFICATE-----",
          client_private_key_pem: "-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----"
        )
      )

      expect(result.success?).to be(true)
      expect(host.reload.client_certificate_pem).to include("BEGIN CERTIFICATE")
      expect(host.setup_step("client_tls")).to include("status" => "verified")
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

    it "creates a self-signed server certificate when SANs are supplied" do
      result = described_class.call(
        host: host,
        action: "generate_server_material",
        params: ActionController::Parameters.new(
          server_common_name: "docker.example.test",
          server_sans: "docker.example.test,100.113.201.1",
          server_mode: "self_signed"
        )
      )

      expect(result.success?).to be(true)
      expect(host.reload.server_certificate_pem).to include("BEGIN CERTIFICATE")
      expect(host.server_csr_pem).to be_nil
    end

    it "marks the required network verified when the network exists remotely" do
      host.update!(
        client_ca_pem: "ca",
        client_certificate_pem: "cert",
        client_private_key_pem: "key"
      )
      allow(DockerHosts::RemoteBackendSession).to receive(:with_backend).and_yield(
        instance_double(Containers::Backends::RemoteDocker, get_network: true)
      )

      result = described_class.call(
        host: host,
        action: "verify_network",
        params: ActionController::Parameters.new(required_network_name: "shared-agents")
      )

      expect(result.success?).to be(true)
      expect(host.reload.required_network_status).to eq("ready")
      expect(host.setup_step("required_network")).to include("status" => "verified")
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
      expect(result.message).to include("exit status 7")
      expect(host.reload.setup_step("callback_reachability")).to include("status" => "failing")
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
      expect(result.message).to include("exit status 1")
      expect(host.reload.setup_step("dry_run")).to include("status" => "failing")
    end
  end
end
