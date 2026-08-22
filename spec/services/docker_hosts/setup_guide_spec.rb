# frozen_string_literal: true

require "rails_helper"

RSpec.describe DockerHosts::SetupGuide do
  describe "#command_snippets" do
    it "includes TLS client certificate flags for remote docker commands" do
      host = build(
        :docker_host,
        endpoint: "tcp://docker.example.test:2376",
        required_network_name: "shared-agents"
      )

      snippets = described_class.new(host).command_snippets

      expect(snippets.fetch("network_create")).to eq(
        "docker --host tcp://docker.example.test:2376 " \
          "--tlscacert client-ca.pem " \
          "--tlscert client-cert.pem " \
          "--tlskey client-key.pem --tlsverify network create " \
          "--driver bridge --subnet #{NetworkPolicy::NETWORK_SUBNET} #{NetworkPolicy::NETWORK_NAME}"
      )
    end

    it "includes the same driver and subnet options the automated helper applies to the paid_agent network" do
      host = build(
        :docker_host,
        endpoint: "tcp://docker.example.test:2376",
        required_network_name: NetworkPolicy::NETWORK_NAME
      )

      snippets = described_class.new(host).command_snippets

      expect(snippets.fetch("network_create")).to eq(
        "docker --host tcp://docker.example.test:2376 " \
          "--tlscacert client-ca.pem " \
          "--tlscert client-cert.pem " \
          "--tlskey client-key.pem --tlsverify network create " \
          "--driver bridge --subnet #{NetworkPolicy::NETWORK_SUBNET} #{NetworkPolicy::NETWORK_NAME}"
      )
    end

    it "shell-escapes operator-controlled values in generated commands" do
      host = build(
        :docker_host,
        endpoint: "tcp://docker.example.test:2376",
        required_network_name: "shared agents; touch /tmp/pwned",
        image_tag: "paid-agent:latest; touch /tmp/pwned"
      )

      snippets = described_class.new(host).command_snippets

      expect(snippets.fetch("docker_save_load")).to include("docker save paid-agent:latest\\;\\ touch\\ /tmp/pwned")
      expect(snippets.fetch("registry_pull")).to include("docker pull paid-agent:latest\\;\\ touch\\ /tmp/pwned")
      expect(snippets.fetch("remote_build")).to include("docker build -t paid-agent:latest\\;\\ touch\\ /tmp/pwned .")
      expect(snippets.fetch("network_create")).to end_with(
        "network create --driver bridge --subnet #{NetworkPolicy::NETWORK_SUBNET} #{NetworkPolicy::NETWORK_NAME}"
      )
      expect(snippets.fetch("docker_save_load")).not_to include("touch /tmp/pwned |")
      expect(snippets.fetch("registry_pull")).not_to include("docker pull paid-agent:latest; touch /tmp/pwned")
    end

    # @spec CONTAINER-RUNTIME-030
    it "includes a network create snippet for the fixed infra network regardless of the configured network name" do
      host = build(
        :docker_host,
        endpoint: "tcp://docker.example.test:2376",
        required_network_name: "shared-agents"
      )

      snippets = described_class.new(host).command_snippets

      expect(snippets.fetch("infra_network_create")).to eq(
        "docker --host tcp://docker.example.test:2376 " \
          "--tlscacert client-ca.pem " \
          "--tlscert client-cert.pem " \
          "--tlskey client-key.pem --tlsverify network create #{NetworkPolicy::INFRA_NETWORK_NAME}"
      )
    end
  end

  # @spec CONTAINER-RUNTIME-030
  describe "#step_rows" do
    it "reports the infra network step as verified once required_infra_network_status is ready" do
      host = build(:docker_host, required_infra_network_status: "ready")

      rows = described_class.new(host).step_rows
      infra_row = rows.find { |row| row[:key] == "required_infra_network" }

      expect(infra_row[:status]).to eq("verified")
    end

    it "reports the infra network step as pending when required_infra_network_status is unknown" do
      host = build(:docker_host, required_infra_network_status: "unknown")

      rows = described_class.new(host).step_rows
      infra_row = rows.find { |row| row[:key] == "required_infra_network" }

      expect(infra_row[:status]).to eq("pending")
    end
  end
end
