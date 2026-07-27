# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::ProxyUrl, :no_db do
  describe ".resolve" do
    let(:backend_identifier) { "worker-1" }
    let(:remote_backend) { instance_double(Containers::Backends::Base, remote?: true, identifier: backend_identifier) }
    let(:local_backend) { instance_double(Containers::Backends::Base, remote?: false) }
    let(:specific_key) { "PAID_PROXY_EXTERNAL_URL_WORKER_1" }

    around do |example|
      original_proxy_external_url = ENV["PAID_PROXY_EXTERNAL_URL"]
      original_specific_proxy_external_url = ENV[specific_key]
      example.run
    ensure
      ENV["PAID_PROXY_EXTERNAL_URL"] = original_proxy_external_url
      ENV[specific_key] = original_specific_proxy_external_url
    end

    it "returns the default internal URL for local backends" do
      ENV.delete("PAID_PROXY_EXTERNAL_URL")

      expect(described_class.resolve(backend: local_backend, restricted: true))
        .to eq("http://paid-proxy:#{Rails.application.config.x.paid_proxy_port}")
    end

    it "returns a validated external URL for remote backends" do
      ENV["PAID_PROXY_EXTERNAL_URL"] = "https://proxy.example.test:3443"

      expect(described_class.resolve(backend: remote_backend, restricted: true))
        .to eq("https://proxy.example.test:3443")
    end

    it "prefers a per-host external URL for remote backends" do
      ENV["PAID_PROXY_EXTERNAL_URL"] = "https://proxy.example.test:3443"
      ENV[specific_key] = "https://worker-1-proxy.example.test:3443"

      expect(described_class.resolve(backend: remote_backend, restricted: true))
        .to eq("https://worker-1-proxy.example.test:3443")
    end

    it "prefers a backend-configured external URL before environment fallbacks" do
      remote_backend = instance_double(
        Containers::Backends::RemoteDocker,
        remote?: true,
        identifier: backend_identifier,
        proxy_external_url: "https://configured.example.test:3443"
      )
      ENV["PAID_PROXY_EXTERNAL_URL"] = "https://proxy.example.test:3443"
      ENV[specific_key] = "https://worker-1-proxy.example.test:3443"

      expect(described_class.resolve(backend: remote_backend, restricted: true))
        .to eq("https://configured.example.test:3443")
    end

    it "normalizes non-alphanumeric characters in the per-host key" do
      remote_backend = instance_double(Containers::Backends::Base, remote?: true, identifier: "worker-1.internal")
      ENV["PAID_PROXY_EXTERNAL_URL"] = "https://proxy.example.test:3443"
      ENV["PAID_PROXY_EXTERNAL_URL_WORKER_1_INTERNAL"] = "https://worker-1-internal-proxy.example.test:3443"

      expect(described_class.resolve(backend: remote_backend, restricted: true))
        .to eq("https://worker-1-internal-proxy.example.test:3443")
    ensure
      ENV.delete("PAID_PROXY_EXTERNAL_URL_WORKER_1_INTERNAL")
    end

    it "raises when the remote backend has no external proxy URL" do
      ENV.delete("PAID_PROXY_EXTERNAL_URL")
      ENV.delete(specific_key)

      expect {
        described_class.resolve(backend: remote_backend, restricted: true)
      }.to raise_error(ArgumentError, "PAID_PROXY_EXTERNAL_URL or PAID_PROXY_EXTERNAL_URL_<HOST> is required when CONTAINER_BACKEND is remote")
    end

    it "raises for an invalid external URL" do
      ENV["PAID_PROXY_EXTERNAL_URL"] = "not a url"

      expect {
        described_class.resolve(backend: remote_backend, restricted: true)
      }.to raise_error(ArgumentError, /Invalid PAID_PROXY_EXTERNAL_URL|must include scheme and host/)
    end

    it "raises when the external URL is missing a scheme" do
      ENV["PAID_PROXY_EXTERNAL_URL"] = "proxy.example.test:3443"

      expect {
        described_class.resolve(backend: remote_backend, restricted: true)
      }.to raise_error(ArgumentError, "PAID_PROXY_EXTERNAL_URL must include scheme and host")
    end

    it "raises when the external URL does not use http or https" do
      ENV["PAID_PROXY_EXTERNAL_URL"] = "ssh://proxy.example.test:3443"

      expect {
        described_class.resolve(backend: remote_backend, restricted: true)
      }.to raise_error(ArgumentError, "PAID_PROXY_EXTERNAL_URL must use http or https")
    end

    it "raises when the external URL port is out of range" do
      ENV["PAID_PROXY_EXTERNAL_URL"] = "https://proxy.example.test:99999"

      expect {
        described_class.resolve(backend: remote_backend, restricted: true)
      }.to raise_error(ArgumentError, "PAID_PROXY_EXTERNAL_URL port must be between 1 and 65535")
    end
  end
end
