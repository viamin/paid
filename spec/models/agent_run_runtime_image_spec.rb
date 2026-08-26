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

  describe "#clear_runtime_image_selection!" do
    it "removes the persisted runtime image metadata while leaving other external_metadata untouched" do
      agent_run = create(:agent_run)
      agent_run.record_runtime_image_selection!(
        "requested_image" => "paid-agent:latest",
        "resolved_image" => "ghcr.io/acme/paid-agent@sha256:#{'a' * 64}",
        "digest" => "sha256:#{'a' * 64}"
      )
      agent_run.update!(external_metadata: agent_run.external_metadata.merge("other_key" => { "kept" => true }))

      agent_run.clear_runtime_image_selection!

      expect(agent_run.reload.external_metadata).to eq("other_key" => { "kept" => true })
      expect(agent_run.runtime_image_selection).to be_nil
    end

    it "is a no-op when no runtime image selection is recorded" do
      agent_run = create(:agent_run)
      original_metadata = agent_run.external_metadata

      agent_run.clear_runtime_image_selection!

      expect(agent_run.reload.external_metadata).to eq(original_metadata)
    end
  end

  describe "#reconcile_stale_container!" do
    it "clears the recorded runtime image selection so a replacement container records a fresh resolution" do
      agent_run = create(:agent_run, container_id: "dead-container-id")
      agent_run.record_runtime_image_selection!(
        "requested_image" => "paid-agent:latest",
        "resolved_image" => "ghcr.io/acme/paid-agent@sha256:#{'a' * 64}",
        "digest" => "sha256:#{'a' * 64}"
      )
      allow(agent_run).to receive(:cleanup_container)

      agent_run.send(:reconcile_stale_container!, nil)

      expect(agent_run.reload.container_id).to be_nil
      expect(agent_run.runtime_image_selection).to be_nil
    end
  end

  describe "#clear_runner_reference!" do
    it "clears the recorded runtime image selection alongside container_id and runner_handle" do
      agent_run = create(
        :agent_run,
        container_id: "dead-container-id",
        container_host: "remote",
        runner_handle: { "runner_type" => "local_docker" }
      )
      agent_run.record_runtime_image_selection!(
        "requested_image" => "paid-agent:latest",
        "resolved_image" => "ghcr.io/acme/paid-agent@sha256:#{'a' * 64}",
        "digest" => "sha256:#{'a' * 64}"
      )

      agent_run.send(:clear_runner_reference!)

      expect(agent_run.reload.container_id).to be_nil
      expect(agent_run.container_host).to be_nil
      expect(agent_run.runner_handle).to be_nil
      expect(agent_run.runtime_image_selection).to be_nil
    end
  end
end
