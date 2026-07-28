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
  end
end
