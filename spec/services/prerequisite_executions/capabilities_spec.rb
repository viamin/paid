# frozen_string_literal: true

require "rails_helper"

RSpec.describe PrerequisiteExecutions::Capabilities do # @spec PREREQ-EXEC-001 # @spec PREREQ-EXEC-002 # @spec PREREQ-EXEC-003 # @spec PREREQ-EXEC-004 # @spec PREREQ-EXEC-005
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, created_by: create(:user, account: account)) }

  before do
    FeatureFlags.flipper.features.each(&:remove)
    # Any attempt to reach a live container backend (including the local
    # Docker socket) fails the example: capability inspection reads the
    # provisioner's placement interfaces only.
    allow(Containers).to receive(:backend).and_raise(StandardError, "must not probe a container backend")
    allow(Containers).to receive(:backend_for).and_raise(StandardError, "must not probe a container backend")
  end

  describe "execution-host capability" do
    # @spec PREREQ-EXEC-001
    it "reports an available environment from a placement-ready remote host, without a local Docker socket" do
      create(:docker_host, :local, account: account, identifier: "local", enabled: false)
      create(:docker_host, account: account, identifier: "remote-1", backend_type: "remote")

      report = described_class.call(project: project)

      expect(report.environment_available?).to be(true)
      expect(report.compatible_host_identifiers).to eq([ "remote-1" ])
      expect(report.ready?).to be(true)
      expect(report.missing).to be_empty
    end

    it "snapshots host capability per host" do
      create(:docker_host, account: account, identifier: "remote-1", backend_type: "remote")

      snapshot = described_class.call(project: project).to_h

      expect(snapshot["environment_available"]).to be(true)
      expect(snapshot["compatible_hosts"]).to eq([ "remote-1" ])
    end

    # @spec PREREQ-EXEC-002
    it "reports unavailable with each host's failing readiness signal and the exact setup action when no host is placement-ready" do
      create(:docker_host, account: account, identifier: "remote-1", backend_type: "remote",
        readiness_status: "failing", failing_check: "docker_ping", image_status: "ready")

      report = described_class.call(project: project)

      expect(report.environment_available?).to be(false)
      expect(report.ready?).to be(false)
      requirement = report.missing.sole
      expect(requirement.kind).to eq("host_capability")
      expect(requirement.message).to include("remote-1")
      expect(requirement.authorized_action).to include("Restore readiness on Docker host remote-1")
      expect(requirement.authorized_action).to include("readiness=failing")
      expect(requirement.authorized_action).to include("check=docker_ping")
    end

    it "reports the host-setup action when no backend is configured at all" do
      report = described_class.call(project: project)

      expect(report.environment_available?).to be(false)
      expect(report.missing.sole.authorized_action).to include("Add or enable a Docker host")
    end
  end

  describe "tool authorization policy" do
    let(:tool_image) { "acme/analyzer:latest" }

    # @spec PREREQ-EXEC-003
    it "reports the flag as a missing authorization with the exact admin action while it is off" do
      create(:docker_host, account: account, identifier: "remote-1", backend_type: "remote")

      report = described_class.call(project: project, tool_image: tool_image)

      expect(report.tool_flag_enabled).to be(false)
      requirement = report.missing.sole
      expect(requirement.kind).to eq("tool_flag")
      expect(requirement.message).to include("marketplace_tool_sidecars")
      expect(requirement.authorized_action).to include("enable the marketplace_tool_sidecars feature flag")
      expect(report.ready?).to be(false)
    end

    # @spec PREREQ-EXEC-004
    it "reports the allowlist action for an image the account has not authorized" do
      create(:docker_host, account: account, identifier: "remote-1", backend_type: "remote")
      FeatureFlags.enable!(:marketplace_tool_sidecars, project: project)

      report = described_class.call(project: project, tool_image: tool_image)

      expect(report.tool_flag_enabled).to be(true)
      requirement = report.missing.sole
      expect(requirement.kind).to eq("image_allowlist")
      expect(requirement.message).to include(tool_image)
      expect(requirement.authorized_action).to include(tool_image)
      expect(requirement.authorized_action).to include("allowed service images")
    end

    it "considers an allowlisted image authorized through the provisioner's own evaluation" do
      create(:docker_host, account: account, identifier: "remote-1", backend_type: "remote")
      FeatureFlags.enable!(:marketplace_tool_sidecars, project: project)
      owner = project.account.users.first
      owner.add_role(:owner, project.account) unless AccountMembership.exists?(user: owner, account: project.account)
      create(:user_setting, user: owner, allowed_service_images: [ tool_image ])

      report = described_class.call(project: project, tool_image: tool_image)

      expect(report.image_allowed).to be(true)
      expect(report.missing).to be_empty
      expect(report.ready?).to be(true)
    end

    # @spec PREREQ-EXEC-005
    it "keeps an environment-only validation startable while the flag is off" do
      create(:docker_host, account: account, identifier: "remote-1", backend_type: "remote")

      report = described_class.call(project: project)

      expect(report.ready?).to be(true)
    end
  end
end
