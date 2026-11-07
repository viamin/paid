# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunPatternDetectorJob do
  let(:pattern) do
    AgentRunPatterns::Detect::Pattern.new(
      type: :failure_streak,
      goal: "enhance_issue",
      severity: :error,
      details: {
        fingerprint: "fp-1",
        streak_length: 3,
        total_runs: 3,
        failure_rate: 1.0,
        error_messages: [ "Error" ]
      }
    )
  end
  let(:follow_up_pattern) do
    AgentRunPatterns::Detect::Pattern.new(
      type: :error_cluster,
      goal: "enhance_issue",
      severity: :error,
      details: {
        fingerprint: "fp-2",
        sample_messages: [ "GitHub API error: 403 Forbidden" ]
      }
    )
  end
  let(:diagnosis) do
    AgentRunPatterns::Diagnose::Diagnosis.new(
      root_cause: "GitHub API Error",
      confidence: 1.0,
      proposed_action: "file_issue",
      action_target: { "type" => "project", "id" => "7" },
      evidence_pointers: [ "legacy_messages[0]" ],
      obstacle_kind: "unknown",
      validation_plan: "Review the proposal.",
      uncertainty: "Evidence is limited."
    )
  end

  def capture_continuations
    continuations = []
    allow(described_class).to receive(:perform_later) { |**arguments| continuations << arguments }
    continuations
  end

  before do
    allow(AgentRunPatterns::Detect).to receive(:call).and_return([])
    allow(AgentRunPatterns::Diagnose).to receive(:call).and_return(diagnosis)
    allow(AgentRunPatterns::DailyDiagnosisBudget).to receive(:remaining_for).and_return(5)
    allow(AgentRunPatterns::RecordRemediationDecision).to receive(:call).and_return(double(id: 99, dismissed?: false))
    allow(AgentRunPatterns::Notify).to receive(:call)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:warn)
  end

  describe "GoodJob concurrency" do
    # @spec RUN-OBSTACLE-006
    it "runs on the maintenance queue with a single-flight concurrency key" do
      config = described_class.good_job_concurrency_config

      expect(described_class.new.queue_name).to eq("maintenance")
      expect(config[:total_limit]).to eq(1)
      expect(config[:enqueue_limit]).to eq(1)
      expect(config[:key]).to eq("agent_run_pattern_detector")
      expect(described_class.new.good_job_concurrency_key).to eq("agent_run_pattern_detector")
    end
  end

  describe "#perform" do
    it "is enqueued on the maintenance queue" do
      expect(described_class.new.queue_name).to eq("maintenance")
    end

    # @spec RUN-OBSTACLE-006
    it "keeps the page bounded to a small number of accounts" do
      expect(described_class::ACCOUNT_PAGE_SIZE).to be <= 2
    end

    # @spec RUN-OBSTACLE-006
    it "covers every account in a bounded cycle through durable continuations" do
      stub_const("AgentRunPatternDetectorJob::ACCOUNT_PAGE_SIZE", 1)
      first_account = create(:account)
      second_account = create(:account)
      continuations = capture_continuations

      described_class.perform_now

      expect(AgentRunPatterns::Detect).to have_received(:call).with(account: first_account)
      expect(AgentRunPatterns::Detect).not_to have_received(:call).with(account: second_account)
      expect(continuations).to contain_exactly(
        after_account_id: first_account.id,
        through_account_id: second_account.id
      )

      described_class.perform_now(**continuations.shift)

      expect(AgentRunPatterns::Detect).to have_received(:call).with(account: second_account)
      expect(continuations).to be_empty
      expect(first_account.id).to be < second_account.id
    end

    # @spec RUN-OBSTACLE-006
    it "iterates accounts within system access" do
      create(:account)
      seen_bypass = nil
      allow(AgentRunPatterns::Detect).to receive(:call) do |account:|
        seen_bypass = TenantContext.bypass_enabled?
        []
      end
      allow(TenantContext).to receive(:with_system_access).and_call_original

      described_class.perform_now

      expect(TenantContext).to have_received(:with_system_access).at_least(:once)
      expect(seen_bypass).to be(true)
    end

    context "when detection raises for one account" do
      let!(:failing_account) { create(:account) }
      let!(:healthy_account) { create(:account) }
      let!(:continuations) { capture_continuations }
      let(:max_failures) { 1 }

      before do
        stub_const("AgentRunPatternDetectorJob::ACCOUNT_PAGE_SIZE", 2)
        attempts = 0
        allow(AgentRunPatterns::Detect).to receive(:call) do |account:|
          raise "boom" if account == failing_account && (attempts += 1) <= max_failures

          []
        end
      end

      # @spec RUN-OBSTACLE-006
      it "logs the first failure as retryable and enqueues a bounded retry continuation" do
        described_class.perform_now

        expect(Rails.logger).to have_received(:warn).with(
          hash_including(
            message: "agent_run_patterns.detection_failed_for_account",
            account_id: failing_account.id,
            attempt: 1,
            retry_exhausted: false,
            error_class: "RuntimeError"
          )
        )
        expect(continuations).to contain_exactly(
          after_account_id: healthy_account.id,
          through_account_id: healthy_account.id,
          pending_accounts: { failing_account.id.to_s => 1 }
        )
      end

      # @spec RUN-OBSTACLE-006
      it "continues the rest of the cycle while the account is pending retry" do
        described_class.perform_now

        expect(AgentRunPatterns::Notify).to have_received(:call).with(
          account: healthy_account,
          patterns: [],
          diagnoses: {},
          decisions: {}
        )
      end

      # @spec RUN-OBSTACLE-006
      it "retries the failed account once without repeating healthy accounts" do
        described_class.perform_now
        described_class.perform_now(**continuations.shift)

        expect(AgentRunPatterns::Detect).to have_received(:call).with(account: failing_account).twice
        expect(AgentRunPatterns::Detect).to have_received(:call).with(account: healthy_account).once
        expect(continuations).to be_empty
      end

      context "when the account fails again on retry" do
        let(:max_failures) { Float::INFINITY }

        # @spec RUN-OBSTACLE-006
        it "logs retry exhaustion and stops retrying the account" do
          described_class.perform_now
          described_class.perform_now(**continuations.shift)

          expect(Rails.logger).to have_received(:warn).with(
            hash_including(
              message: "agent_run_patterns.detection_failed_for_account",
              account_id: failing_account.id,
              attempt: 2,
              retry_exhausted: true
            )
          )
          expect(continuations).to be_empty
        end
      end
    end

    # @spec RUN-OBSTACLE-006
    it "defers a persistently failing account after one retry and finishes the cycle" do
      stub_const("AgentRunPatternDetectorJob::ACCOUNT_PAGE_SIZE", 2)
      failing_account = create(:account)
      mid_account = create(:account)
      later_account = create(:account)
      continuations = capture_continuations
      calls = []
      allow(AgentRunPatterns::Detect).to receive(:call) do |account:|
        calls << account
        raise "boom" if account == failing_account

        []
      end

      described_class.perform_now
      described_class.perform_now(**continuations.shift)
      described_class.perform_now(**continuations.shift)

      expect(calls).to eq([ failing_account, mid_account, failing_account, later_account ])
      expect(continuations).to be_empty
    end

    # @spec RUN-OBSTACLE-006
    it "finishes the cycle snapshot when a newer account appears mid-cycle" do
      stub_const("AgentRunPatternDetectorJob::ACCOUNT_PAGE_SIZE", 1)
      first_account = create(:account)
      second_account = create(:account)
      continuations = capture_continuations

      described_class.perform_now
      added_during_cycle = create(:account)
      described_class.perform_now(**continuations.shift)

      expect(AgentRunPatterns::Detect).to have_received(:call).with(account: second_account)
      expect(AgentRunPatterns::Detect).not_to have_received(:call).with(account: added_during_cycle)
      expect(continuations).to be_empty
      expect(first_account.id).to be < second_account.id
    end

    # @spec RUN-OBSTACLE-006
    it "completes without continuations when no accounts exist" do
      continuations = capture_continuations

      described_class.perform_now

      expect(AgentRunPatterns::Detect).not_to have_received(:call)
      expect(continuations).to be_empty
    end

    # @spec RUN-OBSTACLE-006
    it "drops a pending retry whose account disappeared mid-cycle" do
      deleted_account = create(:account)
      deleted_account.destroy!
      continuations = capture_continuations

      described_class.perform_now(
        after_account_id: deleted_account.id,
        through_account_id: deleted_account.id,
        pending_accounts: { deleted_account.id.to_s => 1 }
      )

      expect(AgentRunPatterns::Detect).not_to have_received(:call)
      expect(continuations).to be_empty
    end

    # @spec RUN-OBSTACLE-006
    it "ends the cycle without re-sweeping when the remaining page empties mid-cycle" do
      stub_const("AgentRunPatternDetectorJob::ACCOUNT_PAGE_SIZE", 1)
      first_account = create(:account)
      second_account = create(:account)
      continuations = capture_continuations

      described_class.perform_now
      second_account.destroy!
      described_class.perform_now(**continuations.shift)

      expect(AgentRunPatterns::Detect).to have_received(:call).with(account: first_account).once
      expect(AgentRunPatterns::Detect).not_to have_received(:call).with(account: second_account)
      expect(continuations).to be_empty
      expect(first_account.id).to be < second_account.id
    end

    # @spec RUN-OBSTACLE-006
    it "records per-account duration and allocation metrics" do
      account = create(:account)
      allow(AgentRunPatterns::Detect).to receive(:call).with(account: account).and_return([ pattern ])

      described_class.perform_now

      expect(Rails.logger).to have_received(:info).with(
        hash_including(
          message: "agent_run_patterns.account_completed",
          account_id: account.id,
          pattern_count: 1,
          duration_ms: a_kind_of(Integer),
          allocations: a_kind_of(Integer)
        )
      )
    end

    # @spec RUN-OBSTACLE-006
    it "records page-level duration and allocation metrics" do
      create(:account)

      described_class.perform_now

      expect(Rails.logger).to have_received(:info).with(
        hash_including(
          message: "agent_run_patterns.page_completed",
          account_count: 1,
          pattern_count: 0,
          duration_ms: a_kind_of(Integer),
          allocations: a_kind_of(Integer)
        )
      )
    end

    context "when patterns are detected" do
      let!(:account) { create(:account) }

      before do
        allow(AgentRunPatterns::Detect).to receive(:call).with(account: account).and_return([ pattern ])
      end

      it "diagnoses each detected pattern with account context" do
        described_class.perform_now

        expect(AgentRunPatterns::Diagnose).to have_received(:call).with(
          pattern,
          account: account,
          allow_llm: true
        )
      end

      it "records a remediation proposal without invoking automatic repair" do
        described_class.perform_now

        expect(AgentRunPatterns::RecordRemediationDecision).to have_received(:call).with(
          account: account,
          pattern: pattern,
          diagnosis: diagnosis
        )
      end

      it "notifies for the account with fingerprint-keyed diagnoses and decisions" do
        described_class.perform_now

        expect(AgentRunPatterns::Notify).to have_received(:call).with(
          account: account,
          patterns: [ pattern ],
          diagnoses: hash_including("fp-1" => diagnosis),
          decisions: hash_including("fp-1")
        )
      end

      # @spec RUN-OBSTACLE-003
      it "excludes dismissed decisions from the notification payload" do
        allow(AgentRunPatterns::RecordRemediationDecision).to receive(:call).and_return(double(id: 99, dismissed?: true))

        described_class.perform_now

        expect(AgentRunPatterns::Notify).to have_received(:call).with(
          account: account,
          patterns: [ pattern ],
          diagnoses: {},
          decisions: {}
        )
      end

      it "stops issuing LLM diagnoses after the daily budget is exhausted" do
        allow(AgentRunPatterns::Detect).to receive(:call).with(account: account).and_return([ pattern, follow_up_pattern ])
        allow(AgentRunPatterns::DailyDiagnosisBudget).to receive(:remaining_for).and_return(1)

        described_class.perform_now

        expect(AgentRunPatterns::Diagnose).to have_received(:call).with(
          pattern,
          account: account,
          allow_llm: true
        )
        expect(AgentRunPatterns::Diagnose).to have_received(:call).with(
          follow_up_pattern,
          account: account,
          allow_llm: false
        )
      end
    end

    context "when no patterns are detected" do
      let!(:account) { create(:account) }

      it "skips diagnosis and still runs notification resolution" do
        described_class.perform_now

        expect(AgentRunPatterns::Diagnose).not_to have_received(:call)
        expect(AgentRunPatterns::Notify).to have_received(:call).with(
          account: account,
          patterns: [],
          diagnoses: {},
          decisions: {}
        )
      end
    end
  end
end
