# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRun do
  describe "#record_runtime_image_selection!" do
    it "persists runtime image metadata on the run" do
      agent_run = create(:agent_run)

      agent_run.record_runtime_image_selection!(
        "requested_image" => "paid-agent:latest",
        "resolved_image" => "ghcr.io/acme/paid-agent@sha256:#{'a' * 64}",
        "digest" => "sha256:#{'a' * 64}",
        "architecture" => "amd64",
        "registry" => "ghcr.io",
        "repository" => "acme/paid-agent",
        "provenance_reference" => "base-amd64-2026-08-17"
      )

      expect(agent_run.reload.external_metadata["runtime_image"]).to include(
        "requested_image" => "paid-agent:latest",
        "resolved_image" => "ghcr.io/acme/paid-agent@sha256:#{'a' * 64}",
        "digest" => "sha256:#{'a' * 64}",
        "architecture" => "amd64",
        "registry" => "ghcr.io",
        "repository" => "acme/paid-agent",
        "provenance_reference" => "base-amd64-2026-08-17"
      )
    end
  end
end
