# frozen_string_literal: true

# frozen_string: true

require "rails_helper"

RSpec.describe Prerequisites::CapabilityReport do # @spec PREREQ-EVIDENCE-001 @spec PREREQ-EVIDENCE-004
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:hosts) { { "local" => healthy_payload("local") } }

  def healthy_payload(host)
    { host: host, healthy: true, checked_at: Time.current, failing_check: nil, remediation_hint: nil, checks: [] }
  end

  def unhealthy_payload(host, check: "docker_ping", hint: "Ensure Docker is running and reachable on #{host}.")
    { host: host, healthy: false, checked_at: Time.current, failing_check: check, remediation_hint: hint, checks: [] }
  end

  def report_for(hosts_payload)
    described_class.new(project:, host_readiness: host_readiness_double(hosts_payload)).call
  end

  def host_readiness_double(hosts_payload)
    instance_double(Containers::HostReadiness).tap do |double|
      allow(double).to receive(:call).and_return(hosts_payload)
    end
  end

  before do
    allow(FeatureFlags).to receive(:enabled?).and_call_original
  end

  def grant_account_owner_role!
    AccountMembership.find_by!(account: account, user: user).update!(role: :owner)
  end

  describe "execution-host capability inspection" do
    it "reports each configured backend through its own readiness probe" do
      payload = report_for("local" => healthy_payload("local"), "remote" => unhealthy_payload("remote"))

      expect(payload.hosts.keys).to contain_exactly("local", "remote")
      expect(payload.compatible_host).to eq("local")
      expect(payload.healthy_host_identifiers).to eq(%w[local])
    end

    it "does not equate a missing local Docker socket with no usable execution environment" do
      payload = report_for(
        "local" => unhealthy_payload("local", check: "docker_ping"),
        "remote" => healthy_payload("remote")
      )

      expect(payload.hosts["local"][:healthy]).to be(false)
      expect(payload.compatible_host).to eq("remote")
      expect(payload.compatible_host?).to be(true)
    end

    it "carries the unhealthy backend's remediation hint as the authorized host action" do
      payload = report_for("local" => unhealthy_payload("local", check: "docker_image", hint: "Load or build the agent image on local."))

      expect(payload.compatible_host?).to be(false)
      expect(payload.host_blockers).to contain_exactly(
        a_hash_including(
          "check" => "execution_host",
          "reason" => a_string_including("docker_image"),
          "authorized_action" => "Load or build the agent image on local."
        )
      )
    end
  end

  describe "tool/authorization policy inspection" do
    it "names the authorized flag enablement action while the rollout flag is off" do
      allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, anything).and_return(false)

      payload = report_for(hosts)

      expect(payload.tool_sidecars_enabled?).to be(false)
      expect(payload.tool_sidecar_authorized_action).to include("tenant_settings.features")
      expect(payload.tool_sidecar_authorized_action).to include("account admin")
    end

    it "reports an allowlisted tool entry as available" do
      allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, anything).and_return(true)
      entry = create(:marketplace_entry, account: account, entry_type: "tool", name: "echo-tool")
      version = entry.create_version!(canonical_artifact: { "install_type" => "tool", "image" => "example/echo:1", "port" => 8080 })
      create(:user_setting, user: user, allowed_service_images: %w[example/echo:1])
      grant_account_owner_role!

      payload = report_for(hosts)

      expect(payload.tool_available?).to be(true)
      expect(payload.tool_image).to eq("example/echo:1")
      expect(payload.tool_entry).to include("name" => "echo-tool", "version" => version.version)
    end

    it "names the allowlist action for a denied tool image without bypassing the gate" do
      allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, anything).and_return(true)
      entry = create(:marketplace_entry, account: account, entry_type: "tool", name: "denied-tool")
      entry.create_version!(canonical_artifact: { "install_type" => "tool", "image" => "denied/image:1", "port" => 8080 })
      create(:user_setting, user: user, allowed_service_images: %w[example/echo:1])
      grant_account_owner_role!

      payload = report_for(hosts)

      expect(payload.tool_image_allowed).to be(false)
      expect(payload.tool_available?).to be(false)
      expect(payload.tool_image_authorized_action).to include("denied/image:1")
      expect(payload.tool_image_authorized_action).to include("allowed service images")
    end

    it "prefers an allowlisted entry over a denied one" do
      allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, anything).and_return(true)
      denied = create(:marketplace_entry, account: account, entry_type: "tool", name: "a-denied")
      denied.create_version!(canonical_artifact: { "install_type" => "tool", "image" => "denied/image:1", "port" => 8080 })
      allowed = create(:marketplace_entry, account: account, entry_type: "tool", name: "b-allowed")
      allowed.create_version!(canonical_artifact: { "install_type" => "tool", "image" => "example/echo:1", "port" => 8080 })
      create(:user_setting, user: user, allowed_service_images: %w[example/echo:1])
      grant_account_owner_role!

      payload = report_for(hosts)

      expect(payload.tool_entry).to include("name" => "b-allowed")
      expect(payload.tool_image_allowed).to be(true)
    end

    it "names the publish action when no tool entry exists" do
      allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, anything).and_return(true)

      payload = report_for(hosts)

      expect(payload.tool_entry).to be_nil
      expect(payload.tool_image_authorized_action).to include("entry_type \"tool\"")
    end
  end

  describe "scope digest" do
    it "changes when the rollout flag state changes" do
      allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, anything).and_return(true)
      enabled_digest = described_class.scope_digest_for(project:)

      allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, anything).and_return(false)
      disabled_digest = described_class.scope_digest_for(project:)

      expect(enabled_digest).not_to eq(disabled_digest)
    end

    it "changes when the allowlist changes" do
      allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, anything).and_return(true)
      grant_account_owner_role!
      create(:user_setting, user: user, allowed_service_images: %w[example/echo:1])
      before_change = described_class.scope_digest_for(project:)

      UserSetting.last.update!(allowed_service_images: %w[example/echo:1 other:2])

      expect(described_class.scope_digest_for(project:)).not_to eq(before_change)
    end
  end
end
