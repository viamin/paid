# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentComboImageCleanupJob do
  let(:job) { described_class.new }
  let(:backend) { instance_double(Containers::Backends::Base, identifier: "local") }
  let(:active_projects) { instance_double(ActiveRecord::Relation) }
  let(:tag) { "paid-agent:go-node-python-ruby" }
  let(:stale_labels) { { Containers::ComboImageBuilder::BUILT_AT_LABEL => 31.days.ago.iso8601 } }
  let(:fresh_labels) { { Containers::ComboImageBuilder::BUILT_AT_LABEL => 1.day.ago.iso8601 } }

  before do
    allow(Containers).to receive(:all_backends).and_return([ backend ])
    allow(Project).to receive(:active).and_return(active_projects)
    allow(active_projects).to receive(:find_each).and_return([])
    allow(backend).to receive(:image_label_sets).with(tag).and_return([ stale_labels ])
  end

  def stub_combo_images(*entries)
    allow(Containers::ComboImageBuilder).to receive(:combo_images).with(backend: backend).and_return(entries)
    stub_label_sets_for(backend, entries)
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
      allow(active_projects).to receive(:find_each) do
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
      allow(active_projects).to receive(:find_each).and_return([ project ])
      stub_resolver(project, image: tag, unsupported_languages: [])
      stub_combo_images(image: tag, id: "sha256:abc", labels: stale_labels)
      allow(backend).to receive(:delete_image)

      job.perform

      expect(backend).not_to have_received(:delete_image)
    end

    it "prunes a combo tag whose only referencing project has an unsupported runtime" do
      project = instance_double(Project)
      allow(active_projects).to receive(:find_each).and_return([ project ])
      stub_resolver(project, image: tag, unsupported_languages: [ "kotlin" ])
      stub_combo_images(image: tag, id: "sha256:abc", labels: stale_labels)
      allow(backend).to receive(:image_in_use?).and_return(false)
      allow(backend).to receive(:delete_image)

      job.perform

      expect(backend).to have_received(:delete_image).with(tag, force: true)
    end

    it "prunes a combo tag when only inactive projects resolve to it" do
      inactive_project = instance_double(Project)
      allow(active_projects).to receive(:find_each).and_return([])
      allow(Project).to receive(:find_each).and_return([ inactive_project ])
      expect(Containers::ImageResolver).not_to receive(:new).with(inactive_project)
      stub_combo_images(image: tag, id: "sha256:abc", labels: stale_labels)
      allow(backend).to receive(:image_in_use?).and_return(false)
      allow(backend).to receive(:delete_image)

      job.perform

      expect(Project).to have_received(:active)
      expect(backend).to have_received(:delete_image).with(tag, force: true)
    end

    it "keeps a combo tag whose build timestamp is within the retention window" do
      stub_combo_images(image: tag, id: "sha256:abc", labels: fresh_labels)
      allow(backend).to receive(:image_in_use?).and_return(false)
      allow(backend).to receive(:image_label_sets).with(tag).and_return([ fresh_labels ])
      allow(backend).to receive(:delete_image)

      job.perform

      expect(backend).not_to have_received(:delete_image)
    end

    it "keeps a combo tag when any healthy node copy is still within the retention window" do
      stub_combo_images(image: tag, id: "sha256:abc", labels: stale_labels)
      allow(backend).to receive(:image_in_use?).and_return(false)
      allow(backend).to receive(:image_label_sets).with(tag).and_return([ stale_labels, fresh_labels ])
      allow(backend).to receive(:delete_image)

      job.perform

      expect(backend).not_to have_received(:delete_image)
    end

    it "keeps a combo tag when any healthy node copy is missing the built-at label" do
      stub_combo_images(image: tag, id: "sha256:abc", labels: stale_labels)
      allow(backend).to receive(:image_in_use?).and_return(false)
      allow(backend).to receive(:image_label_sets).with(tag).and_return([ stale_labels, {} ])
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

    # @spec POLYGLOT-TEST-010
    it "never prunes a paid-agent tag the builder did not produce" do
      # The documented base alias and an operator's own IMAGE_TAG build share
      # the paid-agent namespace but are not combo images, so they must not
      # become prune candidates however old and unreferenced they are.
      allow(Containers::ComboImageBuilder).to receive(:combo_images).with(backend: backend).and_call_original
      allow(backend).to receive_messages(
        list_images: [
          instance_double(Docker::Image, id: "sha256:abc", info: {
            "RepoTags" => [ "paid-agent:ruby-node-python", "paid-agent:v1.0.0" ],
            "Labels" => stale_labels
          })
        ],
        image_in_use?: false
      )
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
    stub_label_sets_for(target_backend, [ entry ])
  end

  def stub_resolver(project, image:, unsupported_languages:)
    resolver = instance_double(Containers::ImageResolver, resolve: image, unsupported_languages: unsupported_languages)
    allow(Containers::ImageResolver).to receive(:new).with(project).and_return(resolver)
  end

  def stub_label_sets_for(target_backend, entries)
    entries.each do |entry|
      allow(target_backend).to receive(:image_label_sets).with(entry.fetch(:image)).and_return([ entry.fetch(:labels, {}) ])
    end
  end
end
