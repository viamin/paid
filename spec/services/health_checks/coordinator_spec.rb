# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Coordinator do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  describe ".call" do
    it "returns a Result with findings, checked_at, and duration_ms" do
      result = described_class.call(scope: :project, subject: project)

      expect(result).to be_a(HealthChecks::Result)
      expect(result.checked_at).to be_within(1.second).of(Time.current)
      expect(result.duration_ms).to be >= 0
      expect(result.findings).to be_an(Array)
    end

    it "composes project and user scope findings for a :project run" do
      project_check = stub_check(scope: :project, message: "project issue", severity: :error)
      user_check = stub_check(scope: :user, message: "user issue", severity: :warning)

      allow(HealthChecks::Registry).to receive(:for_scope).with(:project).and_return([ project_check ])
      allow(HealthChecks::Registry).to receive(:for_scope).with(:user).and_return([ user_check ])
      allow(HealthChecks::Registry).to receive(:for_scope).with(:runner).and_return([])

      result = described_class.call(scope: :project, subject: project)

      scopes = result.findings.map(&:scope).uniq
      expect(scopes).to contain_exactly(:project, :user)
      expect(result.findings).to include(have_attributes(message: "project issue"))
      expect(result.findings).to include(have_attributes(message: "user issue"))
    end

    it "returns a healthy Result when no findings exist" do
      allow(HealthChecks::Registry).to receive(:for_scope).and_return([])
      result = described_class.call(scope: :project, subject: project)

      expect(result).to be_healthy
    end

    it "isolates a raising check as an internal-error finding" do
      raising_check = Class.new(HealthChecks::Check) do
        self.scope = :project

        def self.network? = false
        def self.name = "HealthChecks::Checks::Project::RaisingTest"
        def call = raise(StandardError, "kaboom")
      end

      allow(HealthChecks::Registry).to receive(:for_scope).and_return([ raising_check ])

      result = described_class.call(scope: :project, subject: project)

      expect(result.findings).to include(
        have_attributes(severity: :error, message: /kaboom/, check: "HealthChecks::Checks::Project::RaisingTest")
      )
    end

    it "excludes network checks when include_network is false" do
      network_check = Class.new(HealthChecks::Check) do
        self.scope = :project

        def self.network? = true
        def self.name = "HealthChecks::Checks::Project::NetworkOnly"
        def call = finding(severity: :warning, message: "network result")
      end

      allow(HealthChecks::Registry).to receive(:for_scope).and_return([ network_check ])

      result = described_class.call(scope: :project, subject: project, include_network: false)

      expect(result.findings).to be_empty
    end
  end

  describe HealthChecks::Result do
    it "counts warnings without marking unhealthy" do
      warning = HealthChecks::Finding.new(check: "T", scope: :project, severity: :warning, message: "w")
      result = described_class.new(findings: [ warning ], checked_at: Time.current, duration_ms: 0)

      expect(result).to be_healthy
      expect(result).to be_warnings
      expect(result.counts[:warning]).to eq(1)
    end

    it "is unhealthy when an error finding exists" do
      error = HealthChecks::Finding.new(check: "T", scope: :project, severity: :error, message: "e")
      result = described_class.new(findings: [ error ], checked_at: Time.current, duration_ms: 0)

      expect(result).not_to be_healthy
      expect(result.counts[:error]).to eq(1)
    end

    it "groups findings by scope" do
      project_f = HealthChecks::Finding.new(check: "A", scope: :project, severity: :error, message: "a")
      user_f = HealthChecks::Finding.new(check: "B", scope: :user, severity: :warning, message: "b")
      result = described_class.new(findings: [ project_f, user_f ], checked_at: Time.current, duration_ms: 0)

      expect(result.for_scope(:project)).to eq([ project_f ])
      expect(result.for_scope(:user)).to eq([ user_f ])
    end
  end

  def stub_check(scope:, message:, severity:)
    Class.new(HealthChecks::Check) do
      self.scope = scope

      def self.network? = false
      def self.name = "HealthChecks::Checks::#{scope.capitalize}::StubCheck"
      define_method(:call) { finding(severity: severity, message: message) }
    end
  end
end
