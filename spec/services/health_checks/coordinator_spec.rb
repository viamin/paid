# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Coordinator do
  let(:owner) { create(:user) }
  let(:project) { create(:project, account: owner.account, created_by: owner) }

  before do
    # Clean registry state before each test
    HealthChecks::Registry.instance_variable_set(:@registry, [])
    HealthChecks::Registry.instance_variable_set(:@defaults_loaded, false)
  end

  after do
    HealthChecks::Registry.instance_variable_set(:@registry, [])
    HealthChecks::Registry.instance_variable_set(:@defaults_loaded, false)
  end

  describe "check isolation" do
    let(:raising_check) do
      Class.new(HealthChecks::Check) do
        def self.scope = :project
        def call = raise(StandardError, "boom")
      end
    end

    let(:passing_check) do
      Class.new(HealthChecks::Check) do
        def self.scope = :project
        def call = []
      end
    end

    let(:finding_check) do
      Class.new(HealthChecks::Check) do
        def self.scope = :project
        def call
          [ HealthChecks::Finding.new(code: :test_finding, scope: :project, severity: :warning, title: "test") ]
        end
      end
    end

    before do
      HealthChecks::Registry.register(raising_check)
      HealthChecks::Registry.register(passing_check)
      HealthChecks::Registry.register(finding_check)
    end

    it "converts a raising check into an internal-error finding without failing the run" do
      result = described_class.call(scope: :project, subject: project)

      internal_errors = result.findings.select { |f| f.code == :health_check_internal_error }
      expect(internal_errors.size).to eq(1)
      internal = internal_errors.first
      expect(internal.severity).to eq(:error)
      expect(internal.title).to eq("Internal health check error")
      expect(internal.metadata[:error_class]).to eq("StandardError")
    end

    it "runs other checks even when one raises" do
      result = described_class.call(scope: :project, subject: project)

      test_findings = result.findings.select { |f| f.code == :test_finding }
      expect(test_findings.size).to eq(1)
    end
  end

  describe "include_network filtering" do
    let(:local_check) do
      Class.new(HealthChecks::Check) do
        def self.scope = :project
        def self.network? = false
        def call
          [ HealthChecks::Finding.new(code: :local, scope: :project, severity: :info, title: "local") ]
        end
      end
    end

    let(:network_check) do
      Class.new(HealthChecks::Check) do
        def self.scope = :project
        def self.network? = true
        def call
          [ HealthChecks::Finding.new(code: :network, scope: :project, severity: :info, title: "network") ]
        end
      end
    end

    before do
      HealthChecks::Registry.register(local_check)
      HealthChecks::Registry.register(network_check)
    end

    it "skips network checks when include_network is false" do
      result = described_class.call(scope: :project, subject: project, include_network: false)

      expect(result.findings.map(&:code)).to include(:local)
      expect(result.findings.map(&:code)).not_to include(:network)
    end

    it "runs network checks when include_network is true" do
      result = described_class.call(scope: :project, subject: project, include_network: true)

      expect(result.findings.map(&:code)).to include(:local)
      expect(result.findings.map(&:code)).to include(:network)
    end
  end

  describe "scope composition" do
    let(:project_check) do
      Class.new(HealthChecks::Check) do
        def self.scope = :project
        def call
          [ HealthChecks::Finding.new(code: :proj, scope: :project, severity: :info, title: "proj") ]
        end
      end
    end

    let(:runner_check) do
      Class.new(HealthChecks::Check) do
        def self.scope = :runner
        def call
          [ HealthChecks::Finding.new(code: :run, scope: :runner, severity: :info, title: "run",
                                      subject_type: subject.class.name, subject_id: subject.id) ]
        end
      end
    end

    let(:user_check) do
      Class.new(HealthChecks::Check) do
        def self.scope = :user
        def call
          [ HealthChecks::Finding.new(code: :usr, scope: :user, severity: :info, title: "usr") ]
        end
      end
    end

    before do
      HealthChecks::Registry.register(project_check)
      HealthChecks::Registry.register(runner_check)
      HealthChecks::Registry.register(user_check)
    end

    context "with runners on effective owner" do
      before do
        create(:runner, user: owner, enabled_for_agent_runs: true)
      end

      it "composes runner and user findings when scope is :project" do
        result = described_class.call(scope: :project, subject: project)

        codes = result.findings.map(&:code)
        expect(codes).to include(:proj)
        expect(codes).to include(:run)
        expect(codes).to include(:usr)
      end

      it "includes findings from all three scopes in one Result" do
        result = described_class.call(scope: :project, subject: project)

        expect(result.findings.map(&:scope).uniq).to contain_exactly(:project, :runner, :user)
        expect(result).to be_a(HealthChecks::Result)
      end
    end

    context "when scope is not :project" do
      it "does not compose runner or user findings" do
        result = described_class.call(scope: :runner, subject: create(:runner, user: owner))

        codes = result.findings.map(&:code)
        expect(codes).to include(:run)
        expect(codes).not_to include(:proj)
        expect(codes).not_to include(:usr)
      end
    end
  end

  describe "result metadata" do
    let(:passing_check) do
      Class.new(HealthChecks::Check) do
        def self.scope = :project
        def call = []
      end
    end

    before do
      HealthChecks::Registry.register(passing_check)
    end

    it "sets checked_at and duration_ms on the result" do
      result = described_class.call(scope: :project, subject: project)

      expect(result.checked_at).to be_within(1.second).of(Time.current)
      expect(result.duration_ms).to be >= 0
    end
  end
end
