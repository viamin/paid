# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::ProxyUrl, :no_db do
  describe ".resolve" do
    let(:remote_backend) { instance_double(Containers::Backends::Base, remote?: true) }
    let(:local_backend) { instance_double(Containers::Backends::Base, remote?: false) }

    around do |example|
      original_proxy_external_url = ENV["PAID_PROXY_EXTERNAL_URL"]
      example.run
    ensure
      ENV["PAID_PROXY_EXTERNAL_URL"] = original_proxy_external_url
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

    it "raises when the remote backend has no external proxy URL" do
      ENV.delete("PAID_PROXY_EXTERNAL_URL")

      expect {
        described_class.resolve(backend: remote_backend, restricted: true)
      }.to raise_error(ArgumentError, "PAID_PROXY_EXTERNAL_URL is required when CONTAINER_BACKEND is remote")
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

    it "raises when the external URL port is out of range" do
      ENV["PAID_PROXY_EXTERNAL_URL"] = "https://proxy.example.test:99999"

      expect {
        described_class.resolve(backend: remote_backend, restricted: true)
      }.to raise_error(ArgumentError, "PAID_PROXY_EXTERNAL_URL port must be between 1 and 65535")
    end
  end
end
