# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunPatternDetectorJob do
  include ActiveJob::TestHelper

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
    allow(AgentRunPatterns::Diagnose).to receive(:call).and_return(diagnosis)
    allow(AgentRunPatterns::DailyDiagnosisBudget).to receive(:remaining_for).and_return(5)
    allow(AgentRunPatterns::RecordRemediationDecision).to receive(:call).and_return(double(id: 99, dismissed?: false))
    allow(AgentRunPatterns::Notify).to receive(:call)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:warn)
  end

  describe "#perform" do
    let(:account) { create(:account) }

    it "is enqueued on the maintenance queue" do
      expect(described_class.new.queue_name).to eq("maintenance")
    end

    it "detects patterns for each account within system access" do
      in_system_access = false
      detect_inside_access = nil
      allow(TenantContext).to receive(:with_system_access) do |&block|
        in_system_access = true
        block.call
      ensure
        in_system_access = false
      end
      allow(AgentRunPatterns::Detect).to receive(:call) do |**|
        detect_inside_access = in_system_access
        []
      end

      account
      perform_enqueued_jobs { described_class.perform_now }

      expect(detect_inside_access).to be(true)
    end

    context "when patterns are detected" do
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
      it "skips diagnosis and still runs notification resolution" do
        account
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

    context "with a bounded batch per continuation" do
      before { stub_const("AgentRunPatternDetectorJob::ACCOUNTS_PER_PERFORM", 2) }

      # @spec RUN-OBSTACLE-006
      it "processes one bounded batch and enqueues a keyset continuation" do
        accounts = create_list(:account, 3)

        expect { described_class.perform_now }
          .to have_enqueued_job(described_class).with(
            after_account_id: accounts.second.id,
            cycle_last_account_id: accounts.third.id
          )

        expect(AgentRunPatterns::Detect).to have_received(:call).with(account: accounts.first)
        expect(AgentRunPatterns::Detect).to have_received(:call).with(account: accounts.second)
        expect(AgentRunPatterns::Detect).not_to have_received(:call).with(account: accounts.third)
      end

      # @spec RUN-OBSTACLE-006
      it "resumes from the persisted cursor and completes the cycle without a continuation" do
        accounts = create_list(:account, 3)

        expect do
          described_class.perform_now(after_account_id: accounts.second.id, cycle_last_account_id: accounts.third.id)
        end.not_to have_enqueued_job(described_class)

        expect(AgentRunPatterns::Detect).to have_received(:call).with(account: accounts.third)
        expect(Rails.logger).to have_received(:info).with(hash_including(
          message: "agent_run_patterns.detection_completed",
          accounts_processed: 1,
          total_patterns: 0,
          duration_ms: kind_of(Numeric)
        ))
      end

      # @spec RUN-OBSTACLE-006
      it "eventually covers every account across continuations" do
        accounts = create_list(:account, 5)

        perform_enqueued_jobs { described_class.perform_now }

        accounts.each { |acct| expect(AgentRunPatterns::Detect).to have_received(:call).with(account: acct) }
        expect(AgentRunPatterns::Detect).to have_received(:call).exactly(5).times
      end

      # @spec RUN-OBSTACLE-006
      it "defers accounts created after the captured cycle end to a later cycle" do
        early_accounts = create_list(:account, 2)
        stub_const("AgentRunPatternDetectorJob::ACCOUNTS_PER_PERFORM", 1)

        described_class.perform_now
        late_account = create(:account)

        described_class.perform_now(
          after_account_id: early_accounts.first.id,
          cycle_last_account_id: early_accounts.last.id
        )

        expect(AgentRunPatterns::Detect).to have_received(:call).with(account: early_accounts.second)
        expect(AgentRunPatterns::Detect).not_to have_received(:call).with(account: late_account)

        perform_enqueued_jobs { described_class.perform_now }

        expect(AgentRunPatterns::Detect).to have_received(:call).with(account: late_account)
      end
    end

    context "when detection raises for one account" do
      let(:failing_account) { create(:account) }
      let(:healthy_account) { create(:account) }

      before do
        failing_account
        healthy_account
        allow(AgentRunPatterns::Detect).to receive(:call).with(account: failing_account).and_raise(StandardError, "boom")
      end

      # @spec RUN-OBSTACLE-007
      it "continues processing the remaining accounts of the cycle" do
        perform_enqueued_jobs { described_class.perform_now }

        expect(AgentRunPatterns::Detect).to have_received(:call).with(account: failing_account)
        expect(AgentRunPatterns::Detect).to have_received(:call).with(account: healthy_account)
        expect(AgentRunPatterns::Notify).to have_received(:call).with(
          account: healthy_account,
          patterns: [],
          diagnoses: {},
          decisions: {}
        )
      end

      # @spec RUN-OBSTACLE-007
      it "logs the failed account with per-account duration and allocation metrics" do
        perform_enqueued_jobs { described_class.perform_now }

        expect(Rails.logger).to have_received(:warn).with(hash_including(
          message: "agent_run_patterns.detection_failed_for_account",
          account_id: failing_account.id,
          error_class: "StandardError",
          duration_ms: (a_value >= 0),
          allocated_objects: (a_value >= 0)
        ))
      end

      # @spec RUN-OBSTACLE-007
      it "retries the failed account on the next cycle" do
        perform_enqueued_jobs { described_class.perform_now }

        allow(AgentRunPatterns::Detect).to receive(:call).with(account: failing_account).and_return([])

        perform_enqueued_jobs { described_class.perform_now }

        expect(AgentRunPatterns::Detect).to have_received(:call).with(account: failing_account).exactly(2).times
        expect(AgentRunPatterns::Notify).to have_received(:call).with(
          account: failing_account,
          patterns: [],
          diagnoses: {},
          decisions: {}
        )
      end
    end

    context "when a cycle reprocesses an account" do
      before do
        allow(AgentRunPatterns::Detect).to receive(:call).with(account: account).and_return([ pattern ])
      end

      # @spec RUN-OBSTACLE-007
      it "replays the same idempotent per-account pipeline inputs" do
        2.times { perform_enqueued_jobs { described_class.perform_now } }

        expect(AgentRunPatterns::RecordRemediationDecision).to have_received(:call).with(
          account: account,
          pattern: pattern,
          diagnosis: diagnosis
        ).twice
        expect(AgentRunPatterns::Notify).to have_received(:call).with(
          account: account,
          patterns: [ pattern ],
          diagnoses: hash_including("fp-1" => diagnosis),
          decisions: hash_including("fp-1")
        ).twice
      end
    end

    # @spec RUN-OBSTACLE-007
    it "records per-account duration and allocation metrics" do
      account

      described_class.perform_now

      expect(Rails.logger).to have_received(:info).with(hash_including(
        message: "agent_run_patterns.account_processed",
        account_id: account.id,
        pattern_count: 0,
        duration_ms: (a_value >= 0),
        allocated_objects: (a_value >= 0)
      ))
      expect(Rails.logger).to have_received(:info).with(hash_including(
        message: "agent_run_patterns.detection_completed",
        accounts_processed: 1,
        accounts_failed: 0,
        duration_ms: (a_value >= 0)
      ))
    end
  end

  describe "GoodJob concurrency" do
    # @spec RUN-OBSTACLE-006
    it "prevents overlapping duplicate chains with bounded enqueue and perform limits" do
      config = described_class.good_job_concurrency_config

      expect(config).to include(enqueue_limit: 1, perform_limit: 1)
      expect(config).not_to have_key(:total_limit)
      expect(config[:key]).to eq("agent_run_pattern_detector")
    end
  end

  describe "GoodJob-persisted chains", :good_job do
    around do |example|
      original_adapter = described_class.queue_adapter
      described_class.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)
      example.run
    ensure
      described_class.queue_adapter = original_adapter
      GoodJob::Job.where(job_class: described_class.name).delete_all
    end

    # @spec RUN-OBSTACLE-006
    it "persists and runs cursor-carrying continuations to full coverage" do
      accounts = create_list(:account, 3)
      stub_const("AgentRunPatternDetectorJob::ACCOUNTS_PER_PERFORM", 2)

      described_class.perform_later
      drain_detector_chain

      accounts.each { |acct| expect(AgentRunPatterns::Detect).to have_received(:call).with(account: acct) }
    end

    # @spec RUN-OBSTACLE-006
    it "aborts a fresh scheduled enqueue while a continuation is queued" do
      account = create(:account)
      described_class.perform_later(after_account_id: account.id, cycle_last_account_id: account.id)

      expect(described_class.perform_later).to be(false)
      expect(GoodJob::Job.where(job_class: described_class.name, finished_at: nil).count).to eq(1)
    end

    def drain_detector_chain
      while (good_job = GoodJob::Job.where(job_class: described_class.name, finished_at: nil).order(:created_at).first)
        good_job.perform(lock_id: SecureRandom.uuid)
      end
    end
  end
end
