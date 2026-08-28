# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentComboImageCleanupJob do
  let(:job) { described_class.new }
  let(:backend) { instance_double(Containers::Backends::Base, identifier: "local") }
  let(:tag) { "paid-agent:go-node-python-ruby" }
  let(:stale_labels) { { Containers::ComboImageBuilder::BUILT_AT_LABEL => 31.days.ago.iso8601 } }
  let(:fresh_labels) { { Containers::ComboImageBuilder::BUILT_AT_LABEL => 1.day.ago.iso8601 } }

  before do
    allow(Containers).to receive(:all_backends).and_return([ backend ])
    allow(Project).to receive(:find_each).and_return([])
  end

  def stub_combo_images(*entries)
    allow(Containers::ComboImageBuilder).to receive(:combo_images).with(backend: backend).and_return(entries)
  end

  describe "#perform" do
    it "looks up referenced combo tags within system access, bypassing tenant RLS" do
      in_system_access = false
      found_in_system_access = nil
      allow(TenantContext).to receive(:with_system_access) do |&block|
        in_system_access = true
        block.call
      ensure
        in_system_access = false
      end
      allow(Project).to receive(:find_each) do
        found_in_system_access = in_system_access
        []
      end
      stub_combo_images(image: tag, id: "sha256:abc", labels: stale_labels)
      allow(backend).to receive(:image_in_use?).and_return(false)
      allow(backend).to receive(:delete_image)

      job.perform

      expect(TenantContext).to have_received(:with_system_access)
      expect(found_in_system_access).to be(true)
    end

    it "checks image usage through the backend's image_in_use? contract, not a container-list filter" do
      stub_combo_images(image: tag, id: "sha256:abc", labels: stale_labels)
      allow(backend).to receive(:image_in_use?).with(tag).and_return(false)
      allow(backend).to receive(:delete_image)

      job.perform

      expect(backend).to have_received(:image_in_use?).with(tag)
    end

    it "prunes a stale, unreferenced, unused combo tag" do
      stub_combo_images(image: tag, id: "sha256:abc", labels: stale_labels)
      allow(backend).to receive(:image_in_use?).and_return(false)
      allow(backend).to receive(:delete_image)

      job.perform

      expect(backend).to have_received(:delete_image).with(tag, force: true)
    end

    it "keeps a combo tag still referenced by a project" do
      project = instance_double(Project)
      allow(Project).to receive(:find_each).and_return([ project ])
      allow(Containers::ImageResolver).to receive(:resolve).with(project).and_return(tag)
      stub_combo_images(image: tag, id: "sha256:abc", labels: stale_labels)
      allow(backend).to receive(:delete_image)

      job.perform

      expect(backend).not_to have_received(:delete_image)
    end

    it "keeps a combo tag whose build timestamp is within the retention window" do
      stub_combo_images(image: tag, id: "sha256:abc", labels: fresh_labels)
      allow(backend).to receive(:image_in_use?).and_return(false)
      allow(backend).to receive(:delete_image)

      job.perform

      expect(backend).not_to have_received(:delete_image)
    end

    it "keeps a combo tag currently in use by a container" do
      stub_combo_images(image: tag, id: "sha256:abc", labels: stale_labels)
      allow(backend).to receive(:image_in_use?).with(tag).and_return(true)
      allow(backend).to receive(:delete_image)

      job.perform

      expect(backend).not_to have_received(:delete_image)
    end

    it "conservatively keeps a combo tag when the usage check itself fails" do
      stub_combo_images(image: tag, id: "sha256:abc", labels: stale_labels)
      allow(backend).to receive(:image_in_use?).and_raise(Docker::Error::DockerError, "daemon error")
      allow(backend).to receive(:delete_image)

      job.perform

      expect(backend).not_to have_received(:delete_image)
    end

    it "continues sweeping other backends when one backend fails" do
      other_backend = instance_double(Containers::Backends::Base, identifier: "worker-1")
      allow(Containers).to receive(:all_backends).and_return([ backend, other_backend ])
      allow(Containers::ComboImageBuilder).to receive(:combo_images).with(backend: backend)
        .and_raise(Docker::Error::DockerError, "daemon unreachable")
      stub_combo_images_for(other_backend, image: tag, id: "sha256:abc", labels: stale_labels)
      allow(other_backend).to receive(:image_in_use?).and_return(false)
      allow(other_backend).to receive(:delete_image)

      expect { job.perform }.not_to raise_error

      expect(other_backend).to have_received(:delete_image).with(tag, force: true)
    end
  end

  def stub_combo_images_for(target_backend, **entry)
    allow(Containers::ComboImageBuilder).to receive(:combo_images).with(backend: target_backend).and_return([ entry ])
  end
end
