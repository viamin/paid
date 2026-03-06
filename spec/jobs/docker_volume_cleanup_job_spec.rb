# frozen_string_literal: true

require "rails_helper"

RSpec.describe DockerVolumeCleanupJob do
  let(:job) { described_class.new }

  describe "#perform" do
    it "removes volumes for completed agent runs" do
      completed_run = create(:agent_run, :completed)
      volume = instance_double(Docker::Volume, id: "paid-workspace-#{completed_run.id}", remove: true)
      allow(Docker::Volume).to receive(:all).and_return([ volume ])

      job.perform

      expect(volume).to have_received(:remove)
    end

    it "skips volumes for active agent runs" do
      running_run = create(:agent_run, status: "running")
      volume = instance_double(Docker::Volume, id: "paid-workspace-#{running_run.id}", remove: true)
      allow(Docker::Volume).to receive(:all).and_return([ volume ])

      job.perform

      expect(volume).not_to have_received(:remove)
    end

    it "skips volumes not matching the paid-workspace prefix" do
      volume = instance_double(Docker::Volume, id: "other-volume-123", remove: true)
      allow(Docker::Volume).to receive(:all).and_return([ volume ])

      job.perform

      expect(volume).not_to have_received(:remove)
    end

    it "removes volumes with no matching agent run" do
      volume = instance_double(Docker::Volume, id: "paid-workspace-nonexistent-id", remove: true)
      allow(Docker::Volume).to receive(:all).and_return([ volume ])

      job.perform

      expect(volume).to have_received(:remove)
    end

    it "handles Docker errors when listing volumes" do
      allow(Docker::Volume).to receive(:all).and_raise(Docker::Error::DockerError, "daemon error")

      expect { job.perform }.not_to raise_error
    end

    it "continues processing when individual volume removal fails" do
      completed_run1 = create(:agent_run, :completed)
      completed_run2 = create(:agent_run, :completed)
      volume1 = instance_double(Docker::Volume, id: "paid-workspace-#{completed_run1.id}")
      volume2 = instance_double(Docker::Volume, id: "paid-workspace-#{completed_run2.id}", remove: true)
      allow(volume1).to receive(:remove).and_raise(Docker::Error::DockerError, "volume in use")
      allow(Docker::Volume).to receive(:all).and_return([ volume1, volume2 ])

      job.perform

      expect(volume2).to have_received(:remove)
    end
  end
end
