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
  end

  describe HealthChecks::Result do
    it "counts warnings without marking unhealthy" do
      warning = HealthChecks::Finding.new(code: :t, scope: :project, severity: :warning, title: "w")
      result = described_class.new(findings: [ warning ], checked_at: Time.current, duration_ms: 0)

      expect(result).to be_healthy
      expect(result).to be_warnings
      expect(result.counts[:warning]).to eq(1)
    end

    it "is unhealthy when an error finding exists" do
      error = HealthChecks::Finding.new(code: :t, scope: :project, severity: :error, title: "e")
      result = described_class.new(findings: [ error ], checked_at: Time.current, duration_ms: 0)

      expect(result).not_to be_healthy
      expect(result.counts[:error]).to eq(1)
    end

    it "groups findings by scope" do
      project_finding = HealthChecks::Finding.new(code: :a, scope: :project, severity: :error, title: "a")
      user_finding = HealthChecks::Finding.new(code: :b, scope: :user, severity: :warning, title: "b")
      result = described_class.new(findings: [ project_finding, user_finding ], checked_at: Time.current, duration_ms: 0)

      expect(result.for_scope(:project)).to eq([ project_finding ])
      expect(result.for_scope(:user)).to eq([ user_finding ])
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
          if scope == :runner
            finding.with(subject_type: subject.class.name, subject_id: subject.id)
          else
            finding.with(code: code)
          end
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
end
