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
        category: "llm_provider",
        confidence: 1.0,
        remediation: "Check provider health and credentials."
      )
    end

    let(:diagnoses) { { "enhance_issue" => diagnosis } }

    before do
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    end

    context "with detected patterns" do
      it "publishes an in-app notification" do
        described_class.call(account: account, patterns: [ pattern ], diagnoses: diagnoses)

        notification = Notification.find_by(
          account: account,
          source: "agent_run_pattern_detector"
        )
        expect(notification).to be_present
        expect(notification.severity).to eq("error")
        expect(notification.title).to include("Enhance issue")
        expect(notification.title).to include("LLM Provider Error")
      end

      it "includes pattern metadata" do
        described_class.call(account: account, patterns: [ pattern ], diagnoses: diagnoses)

        notification = Notification.find_by(
          account: account,
          source: "agent_run_pattern_detector"
        )
        expect(notification.metadata).to include(
          "pattern_count" => 1,
          "goals" => [ "enhance_issue" ],
          "worst_goal" => "enhance_issue"
        )
      end

      it "includes root cause in description" do
        described_class.call(account: account, patterns: [ pattern ], diagnoses: diagnoses)

        notification = Notification.find_by(
          account: account,
          source: "agent_run_pattern_detector"
        )
        expect(notification.description).to include("LLM Provider Error")
        expect(notification.description).to include("Check provider health")
      end
    end

    context "with no patterns" do
      it "does not publish a notification" do
        described_class.call(account: account, patterns: [], diagnoses: {})

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
            failure_count: 4,
            total_count: 5,
            failure_rate: 0.8
          }
        )
      end

      it "publishes a warning notification" do
        described_class.call(account: account, patterns: [ warning_pattern ], diagnoses: {})

        notification = Notification.find_by(
          account: account,
          source: "agent_run_pattern_detector"
        )
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
            streak_length: 4,
            total_runs: 5,
            failure_rate: 0.8,
            error_messages: [ "Error" ]
          }
        )
      end

      it "displays the failure rate as a correct percentage" do
        described_class.call(account: account, patterns: [ streak_pattern ], diagnoses: diagnoses)

        notification = Notification.find_by(
          account: account,
          source: "agent_run_pattern_detector"
        )
        expect(notification.description).to include("80%")
      end
    end

    context "when patterns clear" do
      it "resolves notifications for goals no longer failing" do
        described_class.call(account: account, patterns: [ pattern ], diagnoses: diagnoses)

        expect(Notification.where(account: account, source: "agent_run_pattern_detector").active.count).to eq(1)

        described_class.call(account: account, patterns: [], diagnoses: {})

        remaining = Notification.where(account: account, source: "agent_run_pattern_detector").active
        expect(remaining.count).to eq(0)
      end

      it "does not resolve notifications when only some goals have cleared" do
        second_pattern = AgentRunPatterns::Detect::Pattern.new(
          type: :failure_streak,
          goal: "create_pr",
          severity: :error,
          details: { streak_length: 3, total_runs: 3, failure_rate: 1.0, error_messages: [ "Error" ] }
        )
        described_class.call(
          account: account,
          patterns: [ pattern, second_pattern ],
          diagnoses: diagnoses
        )

        expect(Notification.where(account: account, source: "agent_run_pattern_detector").active.count).to eq(1)

        # Only enhance_issue still failing; create_pr cleared
        described_class.call(account: account, patterns: [ pattern ], diagnoses: diagnoses)

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

        described_class.call(account: account, patterns: [ pattern ], diagnoses: diagnoses)

        expect(notification.reload).to be_active
      end
    end
  end

  describe "#pattern_summary", :no_db do
    let(:account) { Struct.new(:id).new(1) }
    let(:service) { described_class.new(account: account, patterns: [], diagnoses: {}) }

    it "renders failure streak rates as percentages before rounding" do
      pattern = AgentRunPatterns::Detect::Pattern.new(
        type: :failure_streak,
        goal: "enhance_issue",
        severity: :error,
        details: { streak_length: 4, total_runs: 5, failure_rate: 0.8 }
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
        details: { streak_length: 3, total_runs: 3, failure_rate: 1.0 }
      )
    end
    let(:service) { described_class.new(account: account, patterns: [ active_pattern ], diagnoses: {}) }

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
end
