# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Coordinator do
  let(:owner) { create(:user) }
  let(:project) { create(:project, account: owner.account, created_by: owner) }

  describe ".call" do
    it "returns a Result with findings, checked_at, and duration_ms" do
      allow(HealthChecks::Registry).to receive(:for_scope).and_return([])

      result = described_class.call(scope: :project, subject: project)

      expect(result).to be_a(HealthChecks::Result)
      expect(result.checked_at).to be_within(1.second).of(Time.current)
      expect(result.duration_ms).to be >= 0
      expect(result.findings).to be_an(Array)
    end

    it "composes project, runner, and user scope findings for a :project run" do
      owner.runners.kept_only.for_agent_runs.update_all(enabled_for_agent_runs: false)
      runner = create(:runner, user: owner, enabled_for_agent_runs: true)
      project_check = stub_check(scope: :project, code: :proj, title: "project issue")
      runner_check = stub_check(scope: :runner, code: :run, title: "runner issue")
      user_check = stub_check(scope: :user, code: :usr, title: "user issue")

      allow(HealthChecks::Registry).to receive(:for_scope).with(:project).and_return([ project_check ])
      allow(HealthChecks::Registry).to receive(:for_scope).with(:runner).and_return([ runner_check ])
      allow(HealthChecks::Registry).to receive(:for_scope).with(:user).and_return([ user_check ])

      result = described_class.call(scope: :project, subject: project)

      expect(result.findings.map(&:scope)).to include(:project, :user, :runner)
      expect(result.findings.map(&:code)).to include(:proj, :usr, :run)
      expect(result.findings.count { |finding| finding.code == :run }).to be >= 1
      expect(result.findings.find { |finding| finding.code == :run }).to have_attributes(
        subject_type: runner.class.name,
        subject_id: runner.id
      )
    end

    it "runs the registered user-scope checks over the project's effective owner" do
      owner.runners.kept_only.for_agent_runs.update_all(enabled_for_agent_runs: false)

      allow(HealthChecks::Registry).to receive(:for_scope).and_call_original
      allow(HealthChecks::Registry).to receive(:for_scope).with(:project).and_return([])
      allow(HealthChecks::Registry).to receive(:for_scope).with(:runner).and_return([])

      result = described_class.call(scope: :project, subject: project, include_network: false)

      expect(result.for_scope(:user).map(&:code)).to include(:no_agent_runners)
    end

    it "does not compose runner or user findings when scope is not :project" do
      runner = create(:runner, user: owner, enabled_for_agent_runs: true)
      runner_check = stub_check(scope: :runner, code: :run, title: "runner issue")

      allow(HealthChecks::Registry).to receive(:for_scope).with(:runner).and_return([ runner_check ])

      result = described_class.call(scope: :runner, subject: runner)

      expect(result.findings.map(&:code)).to contain_exactly(:run)
    end

    it "returns a healthy Result when no findings exist" do
      allow(HealthChecks::Registry).to receive(:for_scope).and_return([])

      result = described_class.call(scope: :project, subject: project)

      expect(result).to be_healthy
    end

    it "isolates a raising check as an internal-error finding" do
      raising_check = build_raising_check
      allow(HealthChecks::Registry).to receive(:for_scope).with(:project).and_return([ raising_check ])
      allow(HealthChecks::Registry).to receive(:for_scope).with(:runner).and_return([])
      allow(HealthChecks::Registry).to receive(:for_scope).with(:user).and_return([])

      result = described_class.call(scope: :project, subject: project)

      expect_internal_error_finding(result)
    end

    it "excludes network checks when include_network is false" do
      local_check = stub_check(scope: :project, code: :local, title: "local", network: false)
      network_check = stub_check(scope: :project, code: :network, title: "network", network: true)

      allow(HealthChecks::Registry).to receive(:for_scope).with(:project).and_return([ local_check, network_check ])
      allow(HealthChecks::Registry).to receive(:for_scope).with(:runner).and_return([])
      allow(HealthChecks::Registry).to receive(:for_scope).with(:user).and_return([])

      result = described_class.call(scope: :project, subject: project, include_network: false)

      expect(result.findings.map(&:code)).to contain_exactly(:local)
    end

    it "includes network checks when include_network is true" do
      local_check = stub_check(scope: :project, code: :local, title: "local", network: false)
      network_check = stub_check(scope: :project, code: :network, title: "network", network: true)

      allow(HealthChecks::Registry).to receive(:for_scope).with(:project).and_return([ local_check, network_check ])
      allow(HealthChecks::Registry).to receive(:for_scope).with(:runner).and_return([])
      allow(HealthChecks::Registry).to receive(:for_scope).with(:user).and_return([])

      result = described_class.call(scope: :project, subject: project, include_network: true)

      expect(result.findings.map(&:code)).to contain_exactly(:local, :network)
    end

    it "uses a passed-in effective_owner instead of calling subject.effective_owner" do
      other_owner = create(:user, account: project.account)
      project_check = stub_check(scope: :project, code: :proj, title: "project issue")
      user_check = stub_check(scope: :user, code: :usr, title: "user issue")

      allow(HealthChecks::Registry).to receive(:for_scope).with(:project).and_return([ project_check ])
      allow(HealthChecks::Registry).to receive(:for_scope).with(:runner).and_return([])
      allow(HealthChecks::Registry).to receive(:for_scope).with(:user).and_return([ user_check ])

      expect(project).not_to receive(:effective_owner)

      result = described_class.call(
        scope: :project,
        subject: project,
        effective_owner: other_owner
      )

      expect(result.for_scope(:user).map(&:subject_id)).to contain_exactly(other_owner.id)
    end

    it "reuses a shared owner_findings_cache instead of recomputing owner findings per project" do
      runner_check = stub_check(scope: :runner, code: :run, title: "runner issue")
      owner_findings_cache = {}
      allow(runner_check).to receive(:call).and_call_original
      first_project, second_project = projects_with_shared_owner

      allow(HealthChecks::Registry).to receive(:for_scope).with(:project).and_return([])
      allow(HealthChecks::Registry).to receive(:for_scope).with(:runner).and_return([ runner_check ])
      allow(HealthChecks::Registry).to receive(:for_scope).with(:user).and_return([])

      described_class.call(
        scope: :project,
        subject: first_project,
        owner_findings_cache: owner_findings_cache
      )
      described_class.call(
        scope: :project,
        subject: second_project,
        owner_findings_cache: owner_findings_cache
      )

      expect(runner_check).to have_received(:call).once
    end
  end

  def stub_check(scope:, code:, title:, network: false, severity: :warning)
    Class.new(HealthChecks::Check) do
      self.scope = scope

      define_singleton_method(:network?) { network }
      define_singleton_method(:name) { "HealthChecks::Checks::#{scope.capitalize}::#{code.to_s.camelize}" }

      define_method(:call) do
        finding(
          severity: severity,
          title: title,
          description: title,
          remediation: nil
        ).map do |finding|
          finding.with(code: code, subject_type: subject.class.name, subject_id: subject.id)
        end
      end
    end.tap do |check|
      allow(check).to receive(:code).and_return(code)
    end
  end

  def build_raising_check
    Class.new(HealthChecks::Check) do
      self.scope = :project

      def self.network? = false
      def self.name = "HealthChecks::Checks::Project::RaisingTest"

      def call
        raise StandardError, "kaboom"
      end
    end
  end

  def expect_internal_error_finding(result)
    expect(result.findings).to contain_exactly(
      have_attributes(
        severity: :error,
        code: :health_check_internal_error,
        title: "Internal health check error",
        description: a_string_including("kaboom"),
        remediation: a_string_including("Re-run the health checks"),
        subject_type: project.class.name,
        subject_id: project.id,
        metadata: include(check_class: "HealthChecks::Checks::Project::RaisingTest", error_class: "StandardError")
      )
    )
  end

  def projects_with_shared_owner
    account = create(:account)
    owner = create(:user, account: account)

    [
      create(:project, created_by: owner, account: account),
      create(:project, created_by: owner, account: account)
    ]
  end
end
