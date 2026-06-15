# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::DispatchCircuitBreaker do
  let(:account) { create(:account) }

  # The service keys providers by Runner#runner_key, but AgentRun#final_runner
  # stores the agent_type (e.g. "claude_code"). Tests use that convention and
  # the resolver normalizes legacy agent_type identifiers through
  # RunnerSupport.runner_key_for_agent_type; for routing_key identifiers it
  # looks up the owning Runner by id. So we configure each active Runner with
  # the canonical settings-level runner_key whose agent_type is used as
  # final_runner in the AgentRun records.
  let(:agent_type_to_runner_key) do
    {
      "claude_code" => "claude",
      "opencode" => "opencode"
    }.freeze
  end

  def create_active_runner(account, runner_key:, auth_type: "subscription", user: nil)
    # User#ensure_default_runner auto-creates a default subscription runner
    # for every new user (in CI, "claude"). The model enforces uniqueness
    # on (user_id, auth_type, runner_key) for kept subscription runners, so
    # adding a second "claude" subscription to the same user is impossible.
    # For the default runner_key, just reuse the auto-created runner —
    # it's already enabled for agent runs and is what production accounts
    # start with. For any other runner_key, install a fresh subscription
    # runner on the user so it appears in the account's active runner set.
    settings_runner_key = agent_type_to_runner_key.fetch(runner_key, runner_key)
    owner = user || create(:user, account: account)
    return owner.runners.kept_only.find_by!(runner_key: settings_runner_key) if settings_runner_key == Runner.default_runner_key
    create(:runner, user: owner, runner_key: settings_runner_key, auth_type: auth_type,
      enabled_for_agent_runs: true)
  end

  def record_outcome_in_threads(thread_count, account:, run_id:)
    mutex = Mutex.new
    cv = ConditionVariable.new
    ready = 0
    threads = thread_count.times.map do
      Thread.new do
        mutex.synchronize do
          ready += 1
          cv.broadcast if ready == thread_count
          cv.wait(mutex) until ready == thread_count
        end
        described_class.record_outcome!(account: account, success: false, agent_run_id: run_id)
      end
    end
    threads.each(&:join)
  end

  describe ".halted?" do
    it "returns false when no breaker exists" do
      expect(described_class.halted?(account)).to be false
    end

    it "returns false when breaker is closed" do
      create(:dispatch_circuit_breaker, account: account)
      expect(described_class.halted?(account)).to be false
    end

    it "returns true when breaker is open" do
      create(:dispatch_circuit_breaker, :open, account: account)
      expect(described_class.halted?(account)).to be true
    end

    it "returns false when breaker transitions to half_open and probe allowed" do
      create(:dispatch_circuit_breaker, :open, account: account,
        circuit_opened_at: 10.minutes.ago)
      expect(described_class.halted?(account)).to be false
    end
  end

  describe ".evaluate!" do
    it "does not trip when there are no recent runs" do
      described_class.evaluate!(account)

      breaker = DispatchCircuitBreaker.for_account(account)
      expect(breaker).to be_persisted
      expect(breaker).to be_circuit_closed
      expect(breaker.last_evaluated_at).to be_present
    end

    it "does not trip when fewer than min_runs" do
      project = create(:project, account: account)
      create_active_runner(account, runner_key: "claude_code")
      5.times do
        create(:agent_run, :failed, project: project, final_runner: "claude",
          completed_at: 5.minutes.ago)
      end

      described_class.evaluate!(account)

      breaker = DispatchCircuitBreaker.for_account(account)
      expect(breaker).to be_persisted
      expect(breaker).to be_circuit_closed
    end

    it "does not trip when only some providers are failing" do
      project = create(:project, account: account)
      create_active_runner(account, runner_key: "claude_code")
      create_active_runner(account, runner_key: "opencode")
      10.times do
        create(:agent_run, :failed, project: project, final_runner: "claude",
          completed_at: 5.minutes.ago)
      end
      10.times do
        create(:agent_run, :completed, project: project, final_runner: "opencode",
          completed_at: 5.minutes.ago)
      end

      described_class.evaluate!(account)

      breaker = DispatchCircuitBreaker.for_account(account)
      expect(breaker).to be_persisted
      expect(breaker).to be_circuit_closed
    end

    it "does not count cancelled or retried runs toward failure rate" do
      project = create(:project, account: account)
      create_active_runner(account, runner_key: "claude_code")
      # Lower min_runs so the 8 provider outcomes exceed the floor; the
      # intent of this test is to verify cancelled/retried runs are
      # excluded from the denominator, not to exercise the min_runs gate.
      account.tenant_setting!.update!(agent_settings: { "dispatch_circuit_breaker_min_runs" => 5 })
      8.times do
        create(:agent_run, :failed, project: project, final_runner: "claude",
          completed_at: 5.minutes.ago)
      end
      # cancelled and retried are not real provider outcomes and must not
      # dilute the failure-rate denominator. With 8 fails / 8 provider outcomes
      # the rate is 1.0 (above 0.8 threshold) and the breaker trips.
      4.times do
        create(:agent_run, :cancelled, project: project, final_runner: "claude",
          completed_at: 5.minutes.ago)
      end
      4.times do
        create(:agent_run, :retried, project: project, final_runner: "claude",
          completed_at: 5.minutes.ago)
      end

      described_class.evaluate!(account)

      breaker = DispatchCircuitBreaker.for_account(account)
      expect(breaker).to be_circuit_open
    end

    it "does not trip when cancelled/retried runs would dilute failure rate" do
      project = create(:project, account: account)
      create_active_runner(account, runner_key: "claude_code")
      # 8 fails + 12 completed → real failure rate 0.4, well below 0.8
      8.times do
        create(:agent_run, :failed, project: project, final_runner: "claude",
          completed_at: 5.minutes.ago)
      end
      12.times do
        create(:agent_run, :completed, project: project, final_runner: "claude",
          completed_at: 5.minutes.ago)
      end
      # Adding non-provider outcomes must not push the rate above the threshold
      5.times do
        create(:agent_run, :cancelled, project: project, final_runner: "claude",
          completed_at: 5.minutes.ago)
      end

      described_class.evaluate!(account)

      breaker = DispatchCircuitBreaker.for_account(account)
      expect(breaker).to be_circuit_closed
    end

    it "trips when all active providers exceed failure threshold" do
      project = create(:project, account: account)
      create_active_runner(account, runner_key: "claude_code")
      create_active_runner(account, runner_key: "opencode")
      10.times do
        create(:agent_run, :failed, project: project, final_runner: "claude",
          completed_at: 5.minutes.ago)
      end
      10.times do
        create(:agent_run, :failed, project: project, final_runner: "opencode",
          completed_at: 5.minutes.ago)
      end

      described_class.evaluate!(account)

      breaker = DispatchCircuitBreaker.for_account(account)
      expect(breaker).to be_persisted
      expect(breaker).to be_circuit_open
      expect(breaker.trip_metadata["total_runs"]).to eq(20)
    end

    it "trips using routing_key identifiers mapped back to runner_key" do
      project = create(:project, account: account)
      runner = create_active_runner(account, runner_key: "claude_code")
      routing_key = runner.routing_key
      12.times do
        create(:agent_run, :failed, project: project, final_runner: routing_key,
          completed_at: 5.minutes.ago)
      end

      described_class.evaluate!(account)

      breaker = DispatchCircuitBreaker.for_account(account)
      expect(breaker).to be_circuit_open
    end

    it "normalizes legacy agent_type final_runner values back to runner_key" do
      project = create(:project, account: account)
      create_active_runner(account, runner_key: "claude_code")
      # "claude_code" is the agent_type, which RunnerSupport maps to "claude"
      12.times do
        create(:agent_run, :failed, project: project, final_runner: "claude_code",
          completed_at: 5.minutes.ago)
      end

      described_class.evaluate!(account)

      breaker = DispatchCircuitBreaker.for_account(account)
      expect(breaker).to be_circuit_open
    end

    it "does not trip when an active provider has no recent traffic" do
      project = create(:project, account: account)
      create_active_runner(account, runner_key: "claude_code")
      create_active_runner(account, runner_key: "opencode")
      # Only claude has recent traffic and it's failing
      12.times do
        create(:agent_run, :failed, project: project, final_runner: "claude",
          completed_at: 5.minutes.ago)
      end

      described_class.evaluate!(account)

      breaker = DispatchCircuitBreaker.for_account(account)
      expect(breaker).to be_persisted
      expect(breaker).to be_circuit_closed
    end

    it "does not trip when account has no active runners" do
      # Expose the "no active runners" code path by ensuring the account
      # has zero `for_agent_runs` rows: don't create a project (which
      # would auto-install a `created_by` user, and that user would
      # auto-install a "claude" subscription runner). AgentRun records
      # aren't required for this test — the breaker should short-circuit
      # on the empty active_runner_keys set before querying runs.
      20.times do
        project = build_stubbed(:project, account: account)
        build_stubbed(:agent_run, :failed, project: project, final_runner: "claude",
          completed_at: 5.minutes.ago)
      end

      described_class.evaluate!(account)

      breaker = DispatchCircuitBreaker.for_account(account)
      expect(breaker).to be_persisted
      expect(breaker).to be_circuit_closed
    end

    it "does not trip when final_runner is a routing_key for a runner outside the account" do
      other_account = create(:account)
      other_runner = create_active_runner(other_account, runner_key: "claude_code")
      routing_key = other_runner.routing_key

      project = create(:project, account: account)
      create_active_runner(account, runner_key: "opencode")
      12.times do
        create(:agent_run, :failed, project: project, final_runner: routing_key,
          completed_at: 5.minutes.ago)
      end

      described_class.evaluate!(account)

      breaker = DispatchCircuitBreaker.for_account(account)
      expect(breaker).to be_persisted
      expect(breaker).to be_circuit_closed
    end

    it "skips the query when circuit is already open" do
      breaker = create(:dispatch_circuit_breaker, :open, account: account)
      original_opened_at = breaker.circuit_opened_at

      described_class.evaluate!(account)

      expect(breaker.reload.circuit_opened_at).to be_within(1.second).of(original_opened_at)
    end

    it "is debounced by the last_evaluated_at interval" do
      project = create(:project, account: account)
      create_active_runner(account, runner_key: "claude_code")
      15.times do
        create(:agent_run, :failed, project: project, final_runner: "claude",
          completed_at: 5.minutes.ago)
      end

      described_class.evaluate!(account)

      breaker = DispatchCircuitBreaker.for_account(account)
      expect(breaker.last_evaluated_at).to be_present
      first_evaluated_at = breaker.last_evaluated_at

      described_class.evaluate!(account)

      expect(breaker.reload.last_evaluated_at).to eq(first_evaluated_at)
    end

    it "serializes a burst of concurrent record_outcome! calls so only one runs the scan" do
      # Reviewer-flagged race: many concurrent terminal completions can
      # each read evaluation_due? == true and each issue their own
      # provider_failure_stats scan. With claim_evaluation! gating the
      # scan under a row lock, only the first caller should advance
      # last_evaluated_at; the rest must short-circuit before the scan.
      project = create(:project, account: account)
      create_active_runner(account, runner_key: "claude_code")
      15.times do
        create(:agent_run, :failed, project: project, final_runner: "claude",
          completed_at: 5.minutes.ago)
      end

      breaker = create(:dispatch_circuit_breaker, account: account, last_evaluated_at: 10.minutes.ago)
      run = create(:agent_run)
      record_outcome_in_threads(5, account: account, run_id: run.id)

      # claim_evaluation! stamps last_evaluated_at exactly once under the
      # row lock. Subsequent callers observe the fresh stamp and return
      # false from claim_evaluation!, skipping the scan.
      expect(breaker.reload.last_evaluated_at).to be_within(2.seconds).of(Time.current)
    end
  end

  describe ".record_outcome!" do
    context "when circuit is half_open" do
      it "records success and closes when threshold reached" do
        probe = create(:agent_run)
        breaker = create(:dispatch_circuit_breaker, :half_open, account: account,
          half_open_success_count: 1, last_probe_run_id: probe.id)

        described_class.record_outcome!(account: account, success: true, agent_run_id: probe.id)

        expect(breaker.reload).to be_circuit_closed
      end

      it "records failure and re-opens when threshold reached" do
        probe = create(:agent_run)
        breaker = create(:dispatch_circuit_breaker, :half_open, account: account,
          half_open_failure_count: 1, last_probe_run_id: probe.id)

        described_class.record_outcome!(account: account, success: false, agent_run_id: probe.id)

        expect(breaker.reload).to be_circuit_open
      end

      it "ignores a stale in-flight run that is not the tracked probe (success)" do
        probe = create(:agent_run)
        stale = create(:agent_run)
        breaker = create(:dispatch_circuit_breaker, :half_open, account: account,
          last_probe_run_id: probe.id, half_open_success_count: 0)

        described_class.record_outcome!(account: account, success: true, agent_run_id: stale.id)

        expect(breaker.reload.half_open_success_count).to eq(0)
        expect(breaker).to be_circuit_half_open
      end

      it "ignores a stale in-flight run that is not the tracked probe (failure)" do
        probe = create(:agent_run)
        stale = create(:agent_run)
        breaker = create(:dispatch_circuit_breaker, :half_open, account: account,
          last_probe_run_id: probe.id, half_open_failure_count: 0)

        described_class.record_outcome!(account: account, success: false, agent_run_id: stale.id)

        expect(breaker.reload.half_open_failure_count).to eq(0)
        expect(breaker).to be_circuit_half_open
      end
    end

    context "when circuit is closed" do
      it "evaluates whether to trip on failure" do
        breaker = create(:dispatch_circuit_breaker, account: account)
        run = create(:agent_run)
        project = create(:project, account: account)
        create_active_runner(account, runner_key: "claude_code")
        15.times do
          create(:agent_run, :failed, project: project, final_runner: "claude",
            completed_at: 5.minutes.ago)
        end

        described_class.record_outcome!(account: account, success: false, agent_run_id: run.id)

        expect(breaker.reload).to be_circuit_open
      end

      it "is debounced — does not re-evaluate within the interval" do
        breaker = create(:dispatch_circuit_breaker, account: account,
          last_evaluated_at: 10.seconds.ago)
        run = create(:agent_run)
        project = create(:project, account: account)
        create_active_runner(account, runner_key: "claude_code")
        15.times do
          create(:agent_run, :failed, project: project, final_runner: "claude",
            completed_at: 5.minutes.ago)
        end

        described_class.record_outcome!(account: account, success: false, agent_run_id: run.id)

        expect(breaker.reload).to be_circuit_closed
      end
    end
  end

  describe ".probe_decision" do
    it "returns :dispatch when no breaker exists" do
      expect(described_class.probe_decision(account)).to eq(:dispatch)
    end

    it "returns :dispatch when breaker is closed" do
      create(:dispatch_circuit_breaker, account: account)
      expect(described_class.probe_decision(account)).to eq(:dispatch)
    end

    it "returns :halt when breaker is open" do
      create(:dispatch_circuit_breaker, :open, account: account)
      expect(described_class.probe_decision(account)).to eq(:halt)
    end

    it "returns :allow_probe when half_open and never probed" do
      create(:dispatch_circuit_breaker, :half_open, account: account, last_probe_at: nil)
      expect(described_class.probe_decision(account)).to eq(:allow_probe)
    end

    it "returns :halt when half_open and recently probed" do
      create(:dispatch_circuit_breaker, :half_open, account: account, last_probe_at: 1.minute.ago)
      expect(described_class.probe_decision(account)).to eq(:halt)
    end

    it "transitions to half_open and returns :allow_probe when open and recovery timeout elapsed" do
      breaker = create(:dispatch_circuit_breaker, :open, account: account,
        circuit_opened_at: 10.minutes.ago)

      expect(described_class.probe_decision(account)).to eq(:allow_probe)
      expect(breaker.reload).to be_circuit_half_open
    end
  end
end
