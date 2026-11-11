# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe Runners::ManagedCredentialLifecycle do # @spec SUBSCRIPTION-RUNNER-AUTH-002 SUBSCRIPTION-RUNNER-AUTH-005
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:valid_codex_auth) { file_fixture("codex_auth_valid.json").read }

  def create_credential(runner_key:, token:, expires_at: nil)
    create(:runner_credential, account: account, created_by: user, runner_key: runner_key,
      auth_kind: "oauth_token", token: token, expires_at: expires_at)
  end

  def refreshed_codex_auth
    payload = JSON.parse(valid_codex_auth)
    payload["tokens"]["access_token"] = "eyJserver-refreshed-access"
    payload
  end

  def rotated_codex_auth
    payload = JSON.parse(valid_codex_auth)
    payload["tokens"]["access_token"] = "eyJrotated-access-token"
    payload["tokens"]["refresh_token"] = "v1.rotated-refresh-token"
    JSON.generate(payload)
  end

  def stub_exchange_supported
    allow(AgentHarness::Authentication).to receive_messages(
      exchange_refresh_token_supported?: true, exchange_refresh_token: refreshed_codex_auth)
  end

  def create_omp_credential(account:, fixture:)
    create(:runner_credential, account: account, created_by: create(:user, account: account), runner_key: "omp",
      auth_kind: "oauth_token", token: file_fixture(fixture).read, expires_at: 1.minute.from_now)
  end

  def stub_blocking_omp_exchange(first_started:, second_started:, release:)
    invocation_count = 0
    allow(AgentHarness::Authentication).to receive(:exchange_refresh_token) do
      invocation = invocation_count += 1
      invocation == 1 ? first_started << true : second_started << true
      release.pop if invocation == 1
      path = File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".credentials.json")
      payload = JSON.parse(File.read(path))
      payload.fetch("claudeAiOauth")["accessToken"] = "refreshed-#{invocation}"
      File.write(path, JSON.generate(payload))
    end
  end

  describe ".rotating?" do
    it "is true only for the rotating managed runners" do
      expect(described_class.rotating?("codex")).to be(true)
      expect(described_class.rotating?("opencode")).to be(true)
      expect(described_class.rotating?("omp")).to be(true)
      expect(described_class.rotating?("claude")).to be(false)
      expect(described_class.rotating?("gemini")).to be(false)
    end
  end

  describe ".near_expiry?" do
    it "uses the stored expiry" do
      credential = create_credential(runner_key: "codex", token: valid_codex_auth,
        expires_at: 5.minutes.from_now)
      expect(described_class.near_expiry?(credential, runner_key: "codex")).to be(true)
    end

    it "falls back to the expiry encoded in the token" do
      credential = create_credential(runner_key: "codex", token: valid_codex_auth, expires_at: nil)
      expect(described_class.near_expiry?(credential, runner_key: "codex")).to be(false)
    end

    it "is false without any expiry signal" do
      credential = create_credential(runner_key: "omp", token: "opaque", expires_at: nil)
      expect(described_class.near_expiry?(credential, runner_key: "omp")).to be(false)
    end
  end

  describe ".refresh_if_near_expiry!" do
    it "refreshes a near-expiry credential under the row lease" do
      credential = create_credential(runner_key: "codex", token: valid_codex_auth,
        expires_at: 1.minute.from_now)
      stub_exchange_supported

      outcome = described_class.refresh_if_near_expiry!(credential, runner_key: "codex", provision: true)

      expect(outcome).to eq(:refreshed)
      expect(JSON.parse(credential.reload.token)["tokens"]["access_token"]).to eq("eyJserver-refreshed-access")
    end

    it "skips when the credential is not near expiry" do
      credential = create_credential(runner_key: "codex", token: valid_codex_auth,
        expires_at: 8.hours.from_now)
      stub_exchange_supported

      outcome = described_class.refresh_if_near_expiry!(credential, runner_key: "codex", provision: true)

      expect(outcome).to eq(:not_needed)
      expect(AgentHarness::Authentication).not_to have_received(:exchange_refresh_token)
    end

    it "does not touch non-rotating runners" do
      credential = create_credential(runner_key: "claude", token: "opaque")
      stub_exchange_supported

      outcome = described_class.refresh_if_near_expiry!(credential, runner_key: "claude", provision: true)

      expect(outcome).to eq(:not_rotating)
      expect(AgentHarness::Authentication).not_to have_received(:exchange_refresh_token)
    end

    it "leaves the credential unchanged when the exchange returns an unusable payload" do
      credential = create_credential(runner_key: "codex", token: valid_codex_auth,
        expires_at: 1.minute.from_now)
      allow(AgentHarness::Authentication).to receive_messages(
        exchange_refresh_token_supported?: true,
        exchange_refresh_token: { "error" => "invalid_grant" })

      outcome = described_class.refresh_if_near_expiry!(credential, runner_key: "codex", provision: true)

      expect(outcome).to eq(:refresh_failed)
      expect(credential.reload.token).to eq(valid_codex_auth)
    end

    it "reports refresh_failed when the harness exchange is unsupported" do
      credential = create_credential(runner_key: "codex", token: valid_codex_auth,
        expires_at: 1.minute.from_now)
      allow(AgentHarness::Authentication).to receive(:exchange_refresh_token_supported?).and_return(false)

      outcome = described_class.refresh_if_near_expiry!(credential, runner_key: "codex", provision: true)

      expect(outcome).to eq(:refresh_failed)
      expect(credential.reload.token).to eq(valid_codex_auth)
    end

    it "serializes OMP exchanges across different credentials" do
      first_credential = create_omp_credential(account: account, fixture: "claude_credentials_valid.json")
      second_credential = create_omp_credential(account: create(:account), fixture: "claude_credentials_expired.json")
      first_exchange_started = Queue.new
      second_exchange_started = Queue.new
      release_first_exchange = Queue.new
      stub_blocking_omp_exchange(first_started: first_exchange_started,
        second_started: second_exchange_started, release: release_first_exchange)

      threads = [ Thread.new { described_class.exchange_refresh_token!(first_credential, runner_key: "omp") } ]
      first_exchange_started.pop
      threads << Thread.new { described_class.exchange_refresh_token!(second_credential, runner_key: "omp") }

      begin
        expect { Timeout.timeout(0.2) { second_exchange_started.pop } }.to raise_error(Timeout::Error)
      ensure
        release_first_exchange.push(true)
        threads.each(&:value)
      end

      expect(JSON.parse(first_credential.reload.token).dig("claudeAiOauth", "accessToken")).to eq("refreshed-1")
      expect(JSON.parse(second_credential.reload.token).dig("claudeAiOauth", "accessToken")).to eq("refreshed-2")
    end
  end

  describe ".harvest" do
    let(:backend) { instance_double(Containers::Backends::LocalDocker) }
    let(:container) { instance_double(Docker::Container) }
    let(:credential) { create_credential(runner_key: "codex", token: valid_codex_auth) }

    def stub_rotation_read(stdout)
      allow(backend).to receive(:exec_in_container).and_return([ Array(stdout), [], 0 ])
    end

    it "persists a rotated codex auth back into the credential" do
      stub_rotation_read(Base64.strict_encode64(rotated_codex_auth))

      result = described_class.harvest(credential: credential, runner_key: "codex",
        backend: backend, container: container)

      expect(result.performed?).to be(true)
      expect(result.reason).to eq("harvested")
      parsed = JSON.parse(credential.reload.token)
      expect(parsed["tokens"]["access_token"]).to eq("eyJrotated-access-token")
      expect(credential.metadata["source"]).to eq("container_rotation_harvest")
      expect(credential.last_used_at).to be_present
    end

    it "skips without a rotated credential" do
      stub_rotation_read(nil)

      result = described_class.harvest(credential: credential, runner_key: "codex",
        backend: backend, container: container)

      expect(result.performed?).to be(false)
      expect(result.reason).to eq("no_rotated_credential")
    end

    it "does not corrupt the credential when the rotation is malformed" do
      stub_rotation_read(Base64.strict_encode64('{"tokens":{}}'))

      result = described_class.harvest(credential: credential, runner_key: "codex",
        backend: backend, container: container)

      expect(result.performed?).to be(false)
      expect(result.reason).to eq("malformed_rotated_credential")
      expect(credential.reload.token).to eq(valid_codex_auth)
    end

    it "rejects a rotation without an access token" do
      refresh_only = JSON.parse(valid_codex_auth)
      refresh_only["tokens"].delete("access_token")
      stub_rotation_read(Base64.strict_encode64(JSON.generate(refresh_only)))

      result = described_class.harvest(credential: credential, runner_key: "codex",
        backend: backend, container: container)

      expect(result.reason).to eq("rotated_credential_missing_access_token")
      expect(credential.reload.token).to eq(valid_codex_auth)
    end

    it "reports harvest_failed when the container exec fails" do
      allow(backend).to receive(:exec_in_container).and_return([ [], [ "boom" ], 1 ])

      result = described_class.harvest(credential: credential, runner_key: "codex",
        backend: backend, container: container)

      expect(result.performed?).to be(false)
      expect(result.reason).to eq("harvest_failed")
    end

    it "persists an opencode rotation into canonical codex auth json" do
      credential = create_credential(runner_key: "opencode", token: valid_codex_auth)
      rotation = JSON.generate("openai" => {
        "type" => "oauth", "access" => "eyJrotated-opencode-access",
        "refresh" => "v1.rotated-opencode-refresh", "expires" => 4102444800000
      })
      stub_rotation_read(Base64.strict_encode64(rotation))

      result = described_class.harvest(credential: credential, runner_key: "opencode",
        backend: backend, container: container)

      expect(result.performed?).to be(true)
      parsed = JSON.parse(credential.reload.token)
      expect(parsed["tokens"]["access_token"]).to eq("eyJrotated-opencode-access")
    end

    it "returns an unsupported result for non-rotating runners" do
      allow(backend).to receive(:exec_in_container)
      result = described_class.harvest(credential: credential, runner_key: "claude",
        backend: backend, container: container)

      expect(result.supported?).to be(false)
      expect(backend).not_to have_received(:exec_in_container)
    end
  end

  describe ".managed_auth_lockfile_path" do
    let(:credential) { create_credential(runner_key: "codex", token: valid_codex_auth) }

    it "keys the lease lockfile on the credential id like Containers::Provision" do
      project = create(:project, account: account, created_by: user)
      agent_run = create(:agent_run, project: project)
      provision = Containers::Provision.new(agent_run: agent_run, project: project,
        backend: instance_double(Containers::Backends::Base, identifier: "local"))

      path = described_class.managed_auth_lockfile_path(runner_key: "codex", credential: credential)

      expect(path).to eq(provision.send(:codex_managed_auth_lockfile_path))
    end

    it "separates credentials onto separate lockfiles" do
      other = create_credential(runner_key: "codex", token: valid_codex_auth)

      expect(described_class.managed_auth_lockfile_path(runner_key: "codex", credential: credential))
        .not_to eq(described_class.managed_auth_lockfile_path(runner_key: "codex", credential: other))
    end
  end

  describe ".with_managed_auth_lease" do
    let(:credential) { create_credential(runner_key: "codex", token: valid_codex_auth) }
    let(:lockfile) { described_class.managed_auth_lockfile_path(runner_key: "codex", credential: credential) }

    around do |example|
      File.delete(lockfile) if File.exist?(lockfile)
      example.run
      File.delete(lockfile) if File.exist?(lockfile)
    end

    it "serializes concurrent lease holders on the same credential" do
      intervals = []
      mutex = Mutex.new
      critical = -> {
        start_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        sleep 0.3
        mutex.synchronize { intervals << [ start_at, Process.clock_gettime(Process::CLOCK_MONOTONIC) ] }
      }

      threads = Array.new(2) do
        Thread.new do
          described_class.with_managed_auth_lease(runner_key: "codex", credential: credential,
            timeout: 10) { critical.call }
        end
      end
      threads.each(&:join)

      sorted = intervals.sort_by(&:first)
      expect(sorted.size).to eq(2)
      expect(sorted[1][0]).to be >= sorted[0][1]
    end

    it "runs without the lease after the lock times out" do
      File.open(lockfile, File::WRONLY | File::CREAT, 0o600) do |held|
        held.flock(File::LOCK_EX | File::LOCK_NB)

        ran = described_class.with_managed_auth_lease(runner_key: "codex", credential: credential,
          timeout: 0) { :ran }

        expect(ran).to eq(:ran)
      end
    end
  end
end
