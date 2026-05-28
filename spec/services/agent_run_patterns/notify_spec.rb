# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunPatterns::Notify do
  describe ".call" do
    let(:account) { create(:account) }
    let(:pattern) do
      AgentRunPatterns::Detect::Pattern.new(
        type: :failure_streak,
        goal: "enhance_issue",
        severity: :error,
        details: {
          fingerprint: "fp-1",
          streak_length: 5,
          total_runs: 5,
          failure_rate: 1.0,
          error_messages: [ "No LLM provider produced an issue enhancement" ]
        }
      )
    end
    let(:diagnosis) do
      AgentRunPatterns::Diagnose::Diagnosis.new(
        root_cause: "LLM Provider Error",
        confidence: 1.0,
        proposed_action: "notify",
        action_target: { "type" => "account", "id" => account.id.to_s },
        evidence_pointers: [ "legacy_messages[0]" ]
      )
    end
    let(:decision) { create(:remediation_decision, account: account, fingerprint: "fp-1") }
    let(:diagnoses) { { "fp-1" => diagnosis } }
    let(:decisions) { { "fp-1" => decision } }

    before do
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    end

    context "with detected patterns" do
      it "publishes an in-app notification" do
        described_class.call(account: account, patterns: [ pattern ], diagnoses: diagnoses, decisions: decisions)

        notification = Notification.find_by(account: account, source: "agent_run_pattern_detector")
        expect(notification).to be_present
        expect(notification.severity).to eq("error")
        expect(notification.title).to include("Enhance issue")
        expect(notification.title).to include("LLM Provider Error")
      end

      it "includes pattern metadata" do
        described_class.call(account: account, patterns: [ pattern ], diagnoses: diagnoses, decisions: decisions)

        notification = Notification.find_by(account: account, source: "agent_run_pattern_detector")
        expect(notification.metadata).to include(
          "pattern_count" => 1,
          "goals" => [ "enhance_issue" ],
          "worst_goal" => "enhance_issue",
          "remediation_decision_id" => decision.id
        )
      end

      it "includes root cause, proposed action, and a decision link" do
        described_class.call(account: account, patterns: [ pattern ], diagnoses: diagnoses, decisions: decisions)

        notification = Notification.find_by(account: account, source: "agent_run_pattern_detector")
        expect(notification.description).to include("LLM Provider Error")
        expect(notification.description).to include("Proposed action: Notify")
        expect(notification.action_url).to eq("/remediation_decisions/#{decision.id}")
      end
    end

    context "with no patterns" do
      it "does not publish a notification" do
        described_class.call(account: account, patterns: [], diagnoses: {}, decisions: {})

        expect(Notification.where(account: account, source: "agent_run_pattern_detector")).not_to exist
      end
    end

    context "with warning severity" do
      let(:warning_pattern) do
        AgentRunPatterns::Detect::Pattern.new(
          type: :high_failure_rate,
          goal: "create_pr",
          severity: :warning,
          details: {
            fingerprint: "fp-warning",
            failure_count: 4,
            total_count: 5,
            failure_rate: 0.8
          }
        )
      end

      it "publishes a warning notification" do
        described_class.call(account: account, patterns: [ warning_pattern ], diagnoses: {}, decisions: {})

        notification = Notification.find_by(account: account, source: "agent_run_pattern_detector")
        expect(notification.severity).to eq("warning")
        expect(notification.description).to include("80% rate")
      end
    end

    context "with failure_streak and sub-1.0 failure rate" do
      let(:streak_pattern) do
        AgentRunPatterns::Detect::Pattern.new(
          type: :failure_streak,
          goal: "enhance_issue",
          severity: :error,
          details: {
            fingerprint: "fp-rate",
            streak_length: 4,
            total_runs: 5,
            failure_rate: 0.8,
            error_messages: [ "Error" ]
          }
        )
      end

      it "displays the failure rate as a correct percentage" do
        described_class.call(account: account, patterns: [ streak_pattern ], diagnoses: diagnoses, decisions: decisions)

        notification = Notification.find_by(account: account, source: "agent_run_pattern_detector")
        expect(notification.description).to include("80%")
      end
    end

    context "when patterns clear" do
      it "resolves notifications for goals no longer failing" do
        described_class.call(account: account, patterns: [ pattern ], diagnoses: diagnoses, decisions: decisions)

        expect(Notification.where(account: account, source: "agent_run_pattern_detector").active.count).to eq(1)

        described_class.call(account: account, patterns: [], diagnoses: {}, decisions: {})

        remaining = Notification.where(account: account, source: "agent_run_pattern_detector").active
        expect(remaining.count).to eq(0)
      end

      it "does not resolve notifications when only some goals have cleared" do
        second_pattern = AgentRunPatterns::Detect::Pattern.new(
          type: :failure_streak,
          goal: "create_pr",
          severity: :error,
          details: { fingerprint: "fp-2", streak_length: 3, total_runs: 3, failure_rate: 1.0, error_messages: [ "Error" ] }
        )

        described_class.call(
          account: account,
          patterns: [ pattern, second_pattern ],
          diagnoses: diagnoses,
          decisions: decisions
        )

        expect(Notification.where(account: account, source: "agent_run_pattern_detector").active.count).to eq(1)

        described_class.call(account: account, patterns: [ pattern ], diagnoses: diagnoses, decisions: decisions)

        remaining = Notification.where(account: account, source: "agent_run_pattern_detector").active
        expect(remaining.count).to eq(1)
      end

      it "does not resolve a notification while any tracked goal remains active" do
        notification = Notification.create!(
          account: account,
          source: "agent_run_pattern_detector",
          subject: account,
          severity: :error,
          title: "Agent run failures detected",
          metadata: { goals: [ "enhance_issue", "create_pr" ] }
        )

        described_class.call(account: account, patterns: [ pattern ], diagnoses: diagnoses, decisions: decisions)

        expect(notification.reload).to be_active
      end
    end
  end

  describe "#pattern_summary", :no_db do
    let(:account) { Struct.new(:id).new(1) }
    let(:service) { described_class.new(account: account, patterns: [], diagnoses: {}, decisions: {}) }

    it "renders failure streak rates as percentages before rounding" do
      pattern = AgentRunPatterns::Detect::Pattern.new(
        type: :failure_streak,
        goal: "enhance_issue",
        severity: :error,
        details: { fingerprint: "fp-summary", streak_length: 4, total_runs: 5, failure_rate: 0.8 }
      )

      expect(service.send(:pattern_summary, pattern)).to include("80% of 5 runs")
    end
  end

  describe "#resolve_cleared_patterns", :no_db do
    let(:account) { Struct.new(:id).new(1) }
    let(:active_pattern) do
      AgentRunPatterns::Detect::Pattern.new(
        type: :failure_streak,
        goal: "enhance_issue",
        severity: :error,
        details: { fingerprint: "fp-active", streak_length: 3, total_runs: 3, failure_rate: 1.0 }
      )
    end
    let(:service) { described_class.new(account: account, patterns: [ active_pattern ], diagnoses: {}, decisions: {}) }

    before do
      stub_const("Notification", Class.new do
        def self.where(...)
          @where_result
        end

        def self.where_result=(value)
          @where_result = value
        end
      end)
      allow(Notifications::Resolve).to receive(:call)
    end

    it "keeps notifications active while any tracked goal remains active" do
      notification = Struct.new(:metadata, :subject, :user).new(
        { "goals" => [ "enhance_issue", "create_pr" ] },
        account,
        nil
      )
      Notification.where_result = Struct.new(:notifications) do
        def active
          notifications
        end
      end.new([ notification ])

      service.send(:resolve_cleared_patterns)

      expect(Notifications::Resolve).not_to have_received(:call)
    end

    it "falls back to worst_goal metadata for legacy notifications" do
      notification = Struct.new(:metadata, :subject, :user).new(
        { "worst_goal" => "enhance_issue" },
        account,
        nil
      )
      Notification.where_result = Struct.new(:notifications) do
        def active
          notifications
        end
      end.new([ notification ])

      service.send(:resolve_cleared_patterns)

      expect(Notifications::Resolve).not_to have_received(:call)
    end

    it "supports symbol-key metadata" do
      notification = Struct.new(:metadata, :subject, :user).new(
        { goals: [ "enhance_issue", "create_pr" ] },
        account,
        nil
      )
      Notification.where_result = Struct.new(:notifications) do
        def active
          notifications
        end
      end.new([ notification ])

      service.send(:resolve_cleared_patterns)

      expect(Notifications::Resolve).not_to have_received(:call)
    end

    it "skips resolving notifications without tracked-goal metadata" do
      notification = Struct.new(:metadata, :subject, :user).new({}, account, nil)
      Notification.where_result = Struct.new(:notifications) do
        def active
          notifications
        end
      end.new([ notification ])

      service.send(:resolve_cleared_patterns)

      expect(Notifications::Resolve).not_to have_received(:call)
    end
  end

  describe "#build_metadata", :no_db do
    let(:account) { Struct.new(:id).new(1) }
    let(:patterns) do
      [
        AgentRunPatterns::Detect::Pattern.new(
          type: :failure_streak,
          goal: "enhance_issue",
          severity: :error,
          details: { fingerprint: "fp-meta-1", streak_length: 3, total_runs: 3, failure_rate: 1.0 }
        ),
        AgentRunPatterns::Detect::Pattern.new(
          type: :error_cluster,
          goal: "create_pr",
          severity: :error,
          details: { fingerprint: "fp-meta-2", error_pattern: "GitHub API error: <N> Forbidden", occurrence_count: 3 }
        )
      ]
    end
    let(:service) { described_class.new(account: account, patterns: patterns, diagnoses: {}, decisions: {}) }

    it "orders metadata deterministically when multiple patterns are active" do
      metadata = service.send(:build_metadata, nil)

      expect(metadata[:goals]).to eq([ "create_pr", "enhance_issue" ])
      expect(metadata[:pattern_types]).to eq([
        "create_pr:error_cluster",
        "enhance_issue:failure_streak"
      ])
      expect(metadata[:worst_goal]).to eq("create_pr")
    end
  end
end
