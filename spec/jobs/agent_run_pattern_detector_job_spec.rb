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

  before do
    allow(AgentRunPatterns::Detect).to receive(:call).and_return([])
    allow(AgentRunPatterns::Diagnose).to receive(:call)
    allow(AgentRunPatterns::DailyDiagnosisBudget).to receive(:remaining_for).and_return(5)
    allow(AgentRunPatterns::RecordRemediationDecision).to receive(:call).and_return(double(id: 99, dismissed?: false))
    allow(AgentRunPatterns::Notify).to receive(:call)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:warn)
  end

  # Drives the starter plus every captured continuation synchronously so a
  # whole cycle completes inside one example.
  def drain_cycle(from: {}, max_pages: 25)
    next_args = from
    performed = 0
    loop do
      performed += 1
      fail "cycle did not terminate after #{max_pages} pages" if performed > max_pages

      captured_args = nil
      allow(AgentRunPatternDetectorContinuationJob).to receive(:perform_later) { |**args| captured_args = args }

      described_class.perform_now(**next_args)

      break unless captured_args

      next_args = captured_args
    end
  end

  describe "queue and concurrency contract" do
    it "is enqueued on the maintenance queue" do
      expect(described_class.new.queue_name).to eq("maintenance")
      expect(AgentRunPatternDetectorContinuationJob.new.queue_name).to eq("maintenance")
    end

    # @spec RUN-OBSTACLE-007
    it "rejects duplicate cycle starts while serializing one detection perform at a time" do
      expect(described_class.good_job_concurrency_config).to include(
        total_limit: 1,
        enqueue_limit: 1,
        key: "agent_run_pattern_detector"
      )
      expect(described_class.new.good_job_concurrency_key).to eq("agent_run_pattern_detector")

      continuation_config = AgentRunPatternDetectorContinuationJob.good_job_concurrency_config
      expect(continuation_config).to include(perform_limit: 1, key: "agent_run_pattern_detector")
      expect(continuation_config).not_to have_key(:enqueue_limit)
      expect(continuation_config).not_to have_key(:total_limit)
      expect(AgentRunPatternDetectorContinuationJob.new.good_job_concurrency_key).to eq("agent_run_pattern_detector")
    end
  end

  describe "#perform" do
    it "sweeps accounts within system access" do
      account = create(:account)
      bypass_states = []
      allow(AgentRunPatterns::Detect).to receive(:call) do |account:|
        bypass_states << TenantContext.bypass_enabled?
        []
      end

      described_class.perform_now

      expect(bypass_states).to eq([ true ])
      expect(AgentRunPatterns::Detect).to have_received(:call).with(account: account)
    end

    # @spec RUN-OBSTACLE-006
    it "processes a bounded account page per perform and enqueues a cursor-carrying continuation" do
      accounts = create_list(:account, 5)
      stub_const("#{described_class.name}::ACCOUNTS_PER_PAGE", 2)
      allow(AgentRunPatternDetectorContinuationJob).to receive(:perform_later)

      described_class.perform_now

      expect(AgentRunPatterns::Detect).to have_received(:call).with(account: accounts[0])
      expect(AgentRunPatterns::Detect).to have_received(:call).with(account: accounts[1])
      expect(AgentRunPatterns::Detect).not_to have_received(:call).with(account: accounts[2])
      expect(AgentRunPatternDetectorContinuationJob).to have_received(:perform_later).with(
        after_account_id: accounts[1].id,
        through_account_id: accounts[4].id
      )
    end

    # @spec RUN-OBSTACLE-006
    it "eventually covers every account exactly once across the continuation chain" do
      accounts = create_list(:account, 5)
      stub_const("#{described_class.name}::ACCOUNTS_PER_PAGE", 2)
      swept = []
      allow(AgentRunPatterns::Detect).to receive(:call) do |account:|
        swept << account
        []
      end

      drain_cycle

      expect(swept.map(&:id)).to eq(accounts.map(&:id))
    end

    # @spec RUN-OBSTACLE-006
    it "captures the cycle end at start and defers accounts created mid-cycle to the next cycle" do
      create_list(:account, 2)
      stub_const("#{described_class.name}::ACCOUNTS_PER_PAGE", 1)
      first_page_args = nil
      allow(AgentRunPatternDetectorContinuationJob).to receive(:perform_later) { |**args| first_page_args = args }

      described_class.perform_now
      late_account = create(:account)

      drain_cycle(from: first_page_args)

      expect(AgentRunPatterns::Detect).not_to have_received(:call).with(account: late_account)

      drain_cycle

      expect(AgentRunPatterns::Detect).to have_received(:call).with(account: late_account)
    end

    # @spec RUN-OBSTACLE-006
    it "logs cycle completion and stops the chain once the captured end is reached" do
      create_list(:account, 2)
      stub_const("#{described_class.name}::ACCOUNTS_PER_PAGE", 1)

      drain_cycle

      expect(Rails.logger).to have_received(:info).with(
        hash_including(
          message: "agent_run_patterns.detection_cycle_completed",
          through_account_id: Account.maximum(:id)
        )
      )
    end

    # @spec RUN-OBSTACLE-006
    it "does nothing when the fleet is empty" do
      allow(AgentRunPatternDetectorContinuationJob).to receive(:perform_later)

      described_class.perform_now

      expect(AgentRunPatterns::Detect).not_to have_received(:call)
      expect(AgentRunPatternDetectorContinuationJob).not_to have_received(:perform_later)
    end

    context "when one account fails" do
      # @spec RUN-OBSTACLE-007
      it "logs the failure with per-account metrics and continues the rest of the page" do
        accounts = create_list(:account, 3)
        allow(AgentRunPatterns::Detect).to receive(:call).with(account: accounts[1]).and_raise("boom")

        described_class.perform_now

        expect(AgentRunPatterns::Detect).to have_received(:call).with(account: accounts[0])
        expect(AgentRunPatterns::Detect).to have_received(:call).with(account: accounts[2])
        expect(AgentRunPatterns::Notify).to have_received(:call).with(
          account: accounts[2], patterns: [], diagnoses: {}, decisions: {}
        )
        expect(Rails.logger).to have_received(:warn).with(
          hash_including(
            message: "agent_run_patterns.detection_failed_for_account",
            account_id: accounts[1].id,
            error_class: "RuntimeError",
            error: "boom",
            duration_ms: a_value >= 0,
            allocations: a_value >= 0
          )
        )
      end

      # @spec RUN-OBSTACLE-007
      it "advances the chain past the failed account without stalling the cycle" do
        accounts = create_list(:account, 3)
        stub_const("#{described_class.name}::ACCOUNTS_PER_PAGE", 1)
        attempted = []
        allow(AgentRunPatterns::Detect).to receive(:call) do |account:|
          attempted << account
          account == accounts[1] ? raise("boom") : []
        end

        drain_cycle

        expect(attempted.map(&:id)).to eq(accounts.map(&:id))
      end

      # @spec RUN-OBSTACLE-007
      it "retries the failed account on the next cycle" do
        accounts = create_list(:account, 2)
        attempt_counts = Hash.new(0)
        allow(AgentRunPatterns::Detect).to receive(:call) do |account:|
          attempt_counts[account.id] += 1
          raise "boom" if account == accounts[0] && attempt_counts[account.id] == 1

          []
        end

        drain_cycle
        drain_cycle

        expect(attempt_counts[accounts[0].id]).to eq(2)
        expect(AgentRunPatterns::Notify).to have_received(:call).with(
          account: accounts[0], patterns: [], diagnoses: {}, decisions: {}
        )
      end
    end

    context "when patterns are detected" do
      before do
        create(:account)
        allow(AgentRunPatterns::Detect).to receive(:call).and_return([ pattern ])
        allow(AgentRunPatterns::Diagnose).to receive(:call).and_return(diagnosis)
      end

      it "diagnoses each detected pattern with account context" do
        described_class.perform_now

        expect(AgentRunPatterns::Diagnose).to have_received(:call).with(
          pattern,
          account: kind_of(Account),
          allow_llm: true
        )
      end

      it "records a remediation proposal without invoking automatic repair" do
        described_class.perform_now

        expect(AgentRunPatterns::RecordRemediationDecision).to have_received(:call).with(
          account: kind_of(Account),
          pattern: pattern,
          diagnosis: diagnosis
        )
      end

      it "notifies for the account with fingerprint-keyed diagnoses and decisions" do
        described_class.perform_now

        expect(AgentRunPatterns::Notify).to have_received(:call).with(
          account: kind_of(Account),
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
          account: kind_of(Account),
          patterns: [ pattern ],
          diagnoses: {},
          decisions: {}
        )
      end

      it "stops issuing LLM diagnoses after the daily budget is exhausted" do
        allow(AgentRunPatterns::Detect).to receive(:call).and_return([ pattern, follow_up_pattern ])
        allow(AgentRunPatterns::DailyDiagnosisBudget).to receive(:remaining_for).and_return(1)

        described_class.perform_now

        expect(AgentRunPatterns::Diagnose).to have_received(:call).with(
          pattern, account: kind_of(Account), allow_llm: true
        )
        expect(AgentRunPatterns::Diagnose).to have_received(:call).with(
          follow_up_pattern, account: kind_of(Account), allow_llm: false
        )
      end
    end

    context "when no patterns are detected" do
      it "skips diagnosis and still runs notification resolution" do
        account = create(:account)

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

    # @spec RUN-OBSTACLE-007
    it "records per-account duration and allocation metrics" do
      account = create(:account)
      allow(AgentRunPatterns::Detect).to receive(:call).with(account: account).and_return([ pattern ])
      allow(AgentRunPatterns::Diagnose).to receive(:call).and_return(diagnosis)

      described_class.perform_now

      expect(Rails.logger).to have_received(:info).with(
        hash_including(
          message: "agent_run_patterns.account_completed",
          account_id: account.id,
          pattern_count: 1,
          duration_ms: a_value >= 0,
          allocations: a_value >= 0
        )
      )
    end

    # @spec RUN-OBSTACLE-007
    it "records per-page duration and allocation metrics" do
      account = create(:account)
      allow(AgentRunPatterns::Detect).to receive(:call).with(account: account).and_return([ pattern ])
      allow(AgentRunPatterns::Diagnose).to receive(:call).and_return(diagnosis)

      described_class.perform_now

      expect(Rails.logger).to have_received(:info).with(
        hash_including(
          message: "agent_run_patterns.detection_page_completed",
          account_count: 1,
          total_patterns: 1,
          through_account_id: account.id,
          duration_ms: a_value >= 0,
          allocations: a_value >= 0,
          peak_rss_kb: anything
        )
      )
    end
  end

  describe "full batches", :good_job do
    around do |example|
      original_starter_adapter = described_class.queue_adapter
      original_continuation_adapter = AgentRunPatternDetectorContinuationJob.queue_adapter
      described_class.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)
      AgentRunPatternDetectorContinuationJob.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)
      example.run
    ensure
      described_class.queue_adapter = original_starter_adapter
      AgentRunPatternDetectorContinuationJob.queue_adapter = original_continuation_adapter
      GoodJob::Job.where(job_class: [ described_class.name, AgentRunPatternDetectorContinuationJob.name ]).delete_all
    end

    # @spec RUN-OBSTACLE-006
    it "persists and runs the cursor-carrying continuation" do
      accounts = create_list(:account, 2)
      stub_const("#{described_class.name}::ACCOUNTS_PER_PAGE", 1)

      starter = described_class.perform_later
      GoodJob::Job.find(starter.provider_job_id).perform(lock_id: SecureRandom.uuid)

      continuation = GoodJob::Job.where(job_class: AgentRunPatternDetectorContinuationJob.name, finished_at: nil).sole
      continuation.perform(lock_id: SecureRandom.uuid)

      expect(AgentRunPatterns::Detect).to have_received(:call).with(account: accounts[0])
      expect(AgentRunPatterns::Detect).to have_received(:call).with(account: accounts[1])
    end

    # @spec RUN-OBSTACLE-007
    it "rejects a duplicate cycle start while a continuation is pending" do
      create_list(:account, 2)
      stub_const("#{described_class.name}::ACCOUNTS_PER_PAGE", 1)

      starter = described_class.perform_later
      GoodJob::Job.find(starter.provider_job_id).perform(lock_id: SecureRandom.uuid)

      duplicate = described_class.perform_later

      expect(starter).to be_successfully_enqueued
      expect(duplicate).to be(false)
      expect(GoodJob::Job.where(job_class: described_class.name, finished_at: nil).count).to eq(0)
    end

    # @spec RUN-OBSTACLE-007
    it "skips a fresh cycle start that slipped past enqueue while a continuation is pending" do
      create(:account)
      allow(AgentRunPatternDetectorContinuationJob).to receive(:perform_later).and_call_original
      AgentRunPatternDetectorContinuationJob.perform_later(after_account_id: 1, through_account_id: 1)

      described_class.perform_now

      expect(AgentRunPatterns::Detect).not_to have_received(:call)
    end
  end
end
