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
          "--tlskey client-key.pem --tlsverify network create shared-agents"
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
      expect(snippets.fetch("network_create")).to end_with("network create shared\\ agents\\;\\ touch\\ /tmp/pwned")
      expect(snippets.fetch("docker_save_load")).not_to include("touch /tmp/pwned |")
      expect(snippets.fetch("registry_pull")).not_to include("docker pull paid-agent:latest; touch /tmp/pwned")
    end
  end
end
