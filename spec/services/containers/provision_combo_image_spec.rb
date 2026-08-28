# frozen_string_literal: true

require "rails_helper"

# Build-on-first-use wiring between Containers::Provision and
# Containers::ComboImageBuilder (RDR-046 / #3613). The builder's own behavior is
# covered by combo_image_builder_spec.rb; this file covers only the provision
# path: the resolved image reaches the builder before the container is created,
# and a build failure fails the provision instead of silently continuing.
RSpec.describe Containers::Provision do
  let(:project) { create(:project, primary_language: "Go") }
  let(:agent_run) { create(:agent_run, project: project) }
  let(:worktree_path) { Dir.mktmpdir("worktree") }
  let(:service) { described_class.new(agent_run: agent_run, worktree_path: worktree_path) }

  let(:mock_container) do
    instance_double(
      Docker::Container,
      id: "abc123container",
      start: true,
      stop: true,
      delete: true,
      refresh!: true,
      info: { "State" => { "Running" => true, "ExitCode" => 0 } },
      exec: nil
    )
  end

  before do
    allow(Docker::Container).to receive(:create).and_return(mock_container)
    allow(Docker::Container).to receive(:get).and_raise(Docker::Error::NotFoundError)
    allow(Docker::Volume).to receive(:create).and_return(instance_double(Docker::Volume, remove: true))
    allow(Docker::Volume).to receive(:get).and_raise(Docker::Error::NotFoundError)
    allow(NetworkPolicy).to receive_messages(ensure_network!: instance_double(Docker::Network), apply_firewall_rules: nil)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("HOME", "/home/vscode").and_return("/tmp/paid-spec-no-local-auth")
  end

  after do
    FileUtils.rm_rf(worktree_path) if worktree_path && Dir.exist?(worktree_path)
  end

  describe "#provision" do
    # @spec POLYGLOT-TEST-007
    it "ensures the resolved combo image exists before creating the container" do
      allow(Containers::ComboImageBuilder).to receive(:ensure_available)

      service.provision

      expect(Containers::ComboImageBuilder).to have_received(:ensure_available)
        .with("paid-agent:go", backend: Containers.backend)
    end

    # @spec POLYGLOT-TEST-008
    it "fails the provision when the combo image cannot be built" do
      allow(Containers::ComboImageBuilder).to receive(:ensure_available)
        .and_raise(Containers::ComboImageBuilder::BuildError, "go layer build failed")

      expect { service.provision }.to raise_error(described_class::ProvisionError, /go layer build failed/)
      expect(Docker::Container).not_to have_received(:create)
    end

    # @spec POLYGLOT-TEST-008
    it "fails the provision for a runtime with no agent image instead of using the base image" do
      project.update!(repo_profile: { "test_languages" => %w[Kotlin Ruby] })

      expect { service.provision }
        .to raise_error(Containers::ImageResolver::UnsupportedRuntimeError, /kotlin/)
      expect(Docker::Container).not_to have_received(:create)
    end
  end
end
