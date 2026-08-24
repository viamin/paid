# frozen_string_literal: true

require "rails_helper"

# @spec EGRESS-POLICY-003
# @spec EGRESS-POLICY-004
# @spec EGRESS-POLICY-005
# @spec EGRESS-POLICY-006
RSpec.describe AgentRuns::EgressPolicy::Resolve do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:agent_run) { create(:agent_run, project: project) }
  let(:networking_policy) { ExecutionRunners::NetworkingPolicy.proxy_restricted }

  def resolve(policy: networking_policy, **options)
    described_class.call(agent_run: agent_run, networking_policy: policy, **options)
  end

  def hosts(destinations)
    destinations.map { |destination| destination["host"] }
  end

  # Agent runs validate that a pinned runner belongs to the project owner,
  # whose user already has the default subscription runner seeded.
  def runner_for(key)
    owner = project.effective_owner
    Runner.find_by(user: owner, runner_key: key, auth_type: "subscription") ||
      create(:runner, runner_key: key, user: owner)
  end

  describe "required destinations" do
    it "includes platform and GitHub destinations for a restricted run" do
      snapshot = resolve

      expect(snapshot.mode).to eq("proxy_restricted")
      expect(hosts(snapshot.required_destinations)).to include("egress-gateway", "paid-proxy", "github.com", "api.github.com")
      expect(snapshot.required_destinations).to all(include("source" => "platform"))
      expect(snapshot.required_destinations).to include(hash_including("reason" => "secrets_proxy"))
      expect(snapshot.required_destinations).to include(hash_including("reason" => "callback_url"))
      expect(snapshot.required_destinations).to include(hash_including("reason" => "github_proxy"))
    end

    it "excludes provider destinations for proxy-restricted runs" do
      agent_run.update!(runner: runner_for("claude"))

      expect(hosts(resolve.destinations)).not_to include("api.anthropic.com")
    end

    it "adds provider destinations for subscription-auth runs" do
      agent_run.update!(runner: runner_for("claude"))
      snapshot = resolve(policy: ExecutionRunners::NetworkingPolicy.subscription_auth)

      provider = snapshot.destinations.select { |d| d["source"] == "runner_provider" }
      expect(hosts(provider)).to include("api.anthropic.com", "claude.ai")
      expect(snapshot.required_destinations).to include(hash_including("host" => "api.anthropic.com"))
    end

    it "adds provider destinations for direct-outbound runs" do
      agent_run.update!(agent_type: "codex")
      snapshot = resolve(policy: ExecutionRunners::NetworkingPolicy.direct_outbound)

      expect(hosts(snapshot.destinations)).to include("chatgpt.com", "api.openai.com")
    end
  end

  describe "secrets proxy destination" do
    let(:proxy_port) { Rails.application.config.x.paid_proxy_port }

    def secrets_proxy_destination(snapshot)
      snapshot.required_destinations.find { |destination| destination["reason"] == "secrets_proxy" }
    end

    it "records the restricted-local paid-proxy host for proxy-restricted runs" do
      proxy = secrets_proxy_destination(resolve)

      expect(proxy).to include("host" => "paid-proxy", "port" => proxy_port, "source" => "platform")
    end

    it "records the web host for unrestricted runs on a local backend" do
      proxy = secrets_proxy_destination(resolve(policy: ExecutionRunners::NetworkingPolicy.subscription_auth))

      expect(proxy).to include("host" => "web", "port" => proxy_port)
    end

    it "records the external proxy URL host and port for remote backends" do
      remote_backend = instance_double(Containers::Backends::Base, remote?: true, identifier: "remote-worker-1")
      Containers::Backends::Resolver.register("remote-worker-1", -> { remote_backend })
      ENV["PAID_PROXY_EXTERNAL_URL"] = "https://proxy.example.test:3443"

      proxy = secrets_proxy_destination(resolve(container_host: "remote-worker-1"))

      expect(proxy).to include("host" => "proxy.example.test", "port" => 3443)
    ensure
      Containers::Backends::Resolver.reset!("remote-worker-1")
      ENV.delete("PAID_PROXY_EXTERNAL_URL")
    end

    it "falls back to the run's persisted container_host when no planned host is given" do
      remote_backend = instance_double(Containers::Backends::Base, remote?: true, identifier: "remote-worker-1")
      Containers::Backends::Resolver.register("remote-worker-1", -> { remote_backend })
      agent_run.update!(container_host: "remote-worker-1")
      ENV["PAID_PROXY_EXTERNAL_URL"] = "https://proxy.example.test:3443"

      proxy = secrets_proxy_destination(resolve)

      expect(proxy).to include("host" => "proxy.example.test", "port" => 3443)
    ensure
      Containers::Backends::Resolver.reset!("remote-worker-1")
      ENV.delete("PAID_PROXY_EXTERNAL_URL")
    end

    it "still honors an explicit platform_destinations override" do
      snapshot = resolve(platform_destinations: [ { "host" => "custom-proxy", "port" => 9999, "source" => "platform", "reason" => "secrets_proxy" } ])

      expect(secrets_proxy_destination(snapshot)).to include("host" => "custom-proxy", "port" => 9999)
    end
  end

  describe "tenant allowlist merge" do
    it "includes enabled account-wide entries (account inheritance)" do
      entry = create(:egress_allowlist_entry, account: account, host_pattern: "api.partner.com", port: 443)

      destination = resolve.destinations.find { |d| d["host"] == "api.partner.com" }

      expect(destination).to include(
        "port" => 443,
        "source" => "account_allowlist",
        "entry_id" => entry.id,
        "reason" => entry.reason
      )
    end

    it "skips disabled entries" do
      create(:egress_allowlist_entry, account: account, host_pattern: "off.partner.com", enabled: false)

      expect(hosts(resolve.destinations)).not_to include("off.partner.com")
    end

    it "skips entries from other accounts" do
      create(:egress_allowlist_entry, host_pattern: "other-account.partner.com")

      expect(hosts(resolve.destinations)).not_to include("other-account.partner.com")
    end

    it "includes project entries alongside inherited account entries" do
      create(:egress_allowlist_entry, account: account, host_pattern: "account.partner.com")
      project_entry = create(:egress_allowlist_entry, account: account, project: project, host_pattern: "project.partner.com")

      destinations = resolve.destinations

      expect(hosts(destinations)).to contain_exactly(
        "egress-gateway", "paid-proxy", "github.com", "api.github.com",
        "account.partner.com", "project.partner.com"
      )
      expect(destinations.find { |d| d["host"] == "project.partner.com" })
        .to include("source" => "project_allowlist", "entry_id" => project_entry.id)
    end

    it "orders destinations deterministically: required, account, project, run-local" do
      create(:egress_allowlist_entry, account: account, host_pattern: "z.account.com")
      create(:egress_allowlist_entry, account: account, host_pattern: "a.account.com")
      create(:egress_allowlist_entry, account: account, project: project, host_pattern: "z.project.com")
      service = create(:service_container, :running, account: account, name: "db", port: 5432)
      agent_run.update!(service_container_ids: [ service.id ])

      ordered_hosts = hosts(resolve(preview_destination: { host: "preview-host", port: 7000 }).destinations)

      expect(ordered_hosts).to eq(
        [
          "egress-gateway", "paid-proxy", "github.com", "api.github.com", # required
          "z.account.com", "a.account.com",                              # account entries by id, not name
          "z.project.com",                                               # project entries by id
          "paid-svc-a#{account.id}-s#{service.id}-db",                   # run services by id, under the provisioning network alias
          "preview-host"                                                 # preview
        ]
      )
    end

    it "keeps required destinations when a tenant entry matches the same host" do
      create(:egress_allowlist_entry, account: account, project: project, host_pattern: "github.com")

      destinations = resolve.destinations
      github = destinations.find { |d| d["host"] == "github.com" }

      expect(destinations.count { |d| d["host"] == "github.com" }).to eq(1)
      expect(github["source"]).to eq("platform")
      expect(github).not_to have_key("entry_id")
    end

    it "drops a tenant entry with no port (any port) that matches a required host, rather than widening it" do
      create(:egress_allowlist_entry, account: account, host_pattern: "github.com", port: nil)

      destinations = resolve.destinations

      expect(destinations.count { |d| d["host"] == "github.com" }).to eq(1)
      expect(destinations.find { |d| d["host"] == "github.com" }).to include("source" => "platform", "port" => 443)
    end
  end

  describe "run-local destinations" do
    # @spec EGRESS-POLICY-003
    it "records running service containers under the provisioning network alias" do
      service = create(:service_container, :running, account: account, name: "pg", port: 5432)
      stopped = create(:service_container, account: account, name: "old", port: 6379)
      agent_run.update!(service_container_ids: [ service.id, stopped.id ])

      destinations = resolve.destinations.select { |d| d["source"] == "run_service" }

      # The alias must match Containers::ServiceRuntimeNaming — the host the
      # container's SERVICE_*_HOST env vars point at — not the service name.
      expect(destinations).to contain_exactly(
        hash_including(
          "host" => "paid-svc-a#{account.id}-s#{service.id}-pg",
          "port" => 5432,
          "category" => "service_container",
          "service_container_id" => service.id
        )
      )
    end

    it "includes the preview destination when supplied" do
      snapshot = resolve(preview_destination: { host: "tunnel.example.com", port: 9000 })

      expect(snapshot.destinations).to include(
        hash_including("host" => "tunnel.example.com", "port" => 9000, "source" => "run_preview",
          "category" => "preview_tunnel")
      )
    end
  end

  describe "unsafe entry rejection" do
    it "denies resolution and excludes an entry that bypassed write-time validation" do
      entry = create(:egress_allowlist_entry, account: account, host_pattern: "api.partner.com")
      entry.update_columns(host_pattern: "169.254.169.254") # simulate a legacy/manual row

      snapshot = resolve

      expect(snapshot).to be_denied
      expect(snapshot.denied_reason).to include("entry #{entry.id}")
      expect(snapshot.denied_reason).to include("must not be an IP literal")
      expect(hosts(snapshot.destinations)).not_to include("169.254.169.254")
    end

    it "raises DeniedPolicyError after persisting the denied snapshot" do
      entry = create(:egress_allowlist_entry, account: account, host_pattern: "api.partner.com")
      entry.update_columns(host_pattern: "169.254.169.254")

      expect {
        described_class.resolve_and_persist!(agent_run, networking_policy: networking_policy)
      }.to raise_error(AgentRuns::EgressPolicy::Resolve::DeniedPolicyError, /must not be an IP literal/)

      persisted = AgentRuns::EgressPolicy::Snapshot.from_record(agent_run.reload)
      expect(persisted).to be_denied
      expect(persisted.denied_reason).to include("entry #{entry.id}")
    end
  end

  describe "egress profile" do
    it "defaults to locked" do
      expect(resolve.egress_profile).to eq("locked")
    end

    it "carries the selected profile" do
      snapshot = resolve(egress_profile: "research")

      expect(snapshot.egress_profile).to eq("research")
    end

    it "rejects unknown profiles" do
      expect {
        resolve(egress_profile: "wild-west")
      }.to raise_error(ArgumentError, /egress_profile/)
    end

    # @spec EGRESS-POLICY-006
    it "falls back to the networking policy's profile when no egress_profile kwarg is given" do
      policy = ExecutionRunners::NetworkingPolicy.proxy_restricted(egress_profile: :research)

      snapshot = resolve(policy: policy)

      expect(snapshot.egress_profile).to eq("research")
    end

    it "prefers an explicit egress_profile kwarg over the networking policy's profile" do
      policy = ExecutionRunners::NetworkingPolicy.proxy_restricted(egress_profile: :research)

      snapshot = resolve(policy: policy, egress_profile: "open")

      expect(snapshot.egress_profile).to eq("open")
    end
  end

  describe "policy derivation" do
    it "derives the network mode from the run when no policy is supplied" do
      # Subscription-auth detection probes host credential mounts through the
      # Docker API; treat them as absent so the derived mode is deterministic.
      allow(Docker::Container).to receive(:get).and_raise(Docker::Error::NotFoundError)

      derived = Containers::Provision.networking_policy_for(agent_run: agent_run, project: project)
      snapshot = described_class.call(agent_run: agent_run)

      expect(snapshot.mode).to eq(derived.mode.to_s)
      expect(snapshot.mode).to be_in(%w[proxy_restricted subscription_auth direct_outbound])
    end
  end

  describe "snapshot persistence" do
    it "persists to external_metadata before provisioning and preserves other keys" do
      agent_run.update!(external_metadata: { "planned_container_host" => "local" })

      snapshot = resolve
      snapshot.persist!(agent_run)

      persisted = AgentRuns::EgressPolicy::Snapshot.from_record(agent_run.reload)
      expect(persisted.mode).to eq("proxy_restricted")
      expect(persisted.destinations.length).to eq(snapshot.destinations.length)
      expect(persisted.resolved_at).to be_within(2.seconds).of(Time.current)
      expect(agent_run.reload.external_metadata["planned_container_host"]).to eq("local")
    end

    it "round-trips through the persisted storage shape" do
      persisted = AgentRuns::EgressPolicy::Snapshot.from_h(resolve.to_h)

      expect(persisted.to_h).to eq(resolve.to_h)
    end
  end
end
