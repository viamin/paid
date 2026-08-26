# frozen_string_literal: true

require "rails_helper"

RSpec.describe Capacity::RequestedResources do
  describe ".for_agent_run" do
    def requested_resources_with_unknown_profile
      {
        "requested_resources" => {
          "profile" => "unknown",
          "cpu_quota" => 123_000,
          "memory_bytes" => 5.gigabytes,
          "disk_bytes" => 2.gigabytes
        }
      }
    end

    def unknown_profile_warning_for(run)
      hash_including(
        message: "capacity.requested_resources.unknown_profile",
        profile_name: "unknown",
        error: 'Unknown execution resource profile: "unknown"',
        agent_run_id: run.id
      )
    end

    # @spec CONTAINER-RUNTIME-027
    it "logs and falls back to explicit values when the requested profile is unknown" do
      project = create(:project)
      run = create(:agent_run, project: project, external_metadata: requested_resources_with_unknown_profile)

      allow(Rails.logger).to receive(:warn)

      expect(described_class.for_agent_run(run)).to eq(
        cpu_quota: 123_000,
        memory_bytes: 5.gigabytes,
        disk_bytes: 2.gigabytes,
        profile: nil
      )

      expect(Rails.logger).to have_received(:warn).with(unknown_profile_warning_for(run))
    end

    # @spec CONTAINER-RUNTIME-027
    # A typoed profile with no numeric overrides must not read as a free run:
    # unset dimensions fall back to the usual default request so admission and
    # accounting still count them against the ceilings.
    it "falls back to the default request when the profile is unknown and no numeric overrides are set" do
      project = create(:project)
      project.effective_owner.settings.update!(container_memory_bytes: 6.gigabytes)
      run = create(:agent_run, project: project, external_metadata: {
        "requested_resources" => { "profile" => "unknown" }
      })

      allow(Rails.logger).to receive(:warn)

      expect(described_class.for_agent_run(run)).to eq(
        cpu_quota: Containers::Provision::DEFAULTS[:cpu_quota],
        memory_bytes: 6.gigabytes,
        disk_bytes: described_class::DISK_BYTES_DEFAULT,
        profile: nil
      )

      expect(Rails.logger).to have_received(:warn).with(unknown_profile_warning_for(run))
    end

    # @spec CONTAINER-RUNTIME-027
    it "keeps partial numeric overrides and defaults only the unset dimensions" do
      project = create(:project)
      run = create(:agent_run, project: project, external_metadata: {
        "requested_resources" => {
          "profile" => "unknown",
          "memory_bytes" => 5.gigabytes
        }
      })

      allow(Rails.logger).to receive(:warn)

      expect(described_class.for_agent_run(run)).to eq(
        cpu_quota: Containers::Provision::DEFAULTS[:cpu_quota],
        memory_bytes: 5.gigabytes,
        disk_bytes: described_class::DISK_BYTES_DEFAULT,
        profile: nil
      )
    end
  end
end
