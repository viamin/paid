# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityPause::Check do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :completed, project: project) }
  let(:prompt) { create(:prompt, :with_version, project: project, account: project.account) }
  let(:prompt_version) { prompt.current_version }

  describe ".call" do
    it "does nothing when the project disables an inherited threshold" do
      create(:quality_threshold, :project_override, :disabled, project: project)
      create_quality_metrics(project, scores: [ 0.2, 0.3, 0.1, 0.4, 0.3 ])

      described_class.call(agent_run: agent_run)

      expect(project.reload.quality_paused?).to be false
    end

    it "does nothing when project is already paused" do
      project.update!(quality_paused_at: Time.current)
      described_class.call(agent_run: agent_run)
      expect(project.quality_pause_events.count).to eq(0)
    end

    it "does nothing when fewer than minimum samples exist" do
      create(:quality_metric, agent_run: agent_run, composite_score: 0.2)
      described_class.call(agent_run: agent_run)
      expect(project.reload.quality_paused?).to be false
    end

    it "does nothing when rolling average is above threshold" do
      create_quality_metrics(project, scores: [ 0.8, 0.7, 0.9, 0.6, 0.8 ])
      described_class.call(agent_run: agent_run)
      expect(project.reload.quality_paused?).to be false
    end

    it "excludes operational failures (timeout, auth_expired, rate_limited, provider exhaustion) from scoring" do
      good_run = create(:agent_run, :completed, project: project)
      create(:quality_metric, agent_run: good_run, composite_score: 0.9)

      AgentRun::QUALITY_EXCLUDED_STATUSES.each do |status|
        bad_run = create(:agent_run, status: status, project: project, goal: agent_run.goal)
        create(:quality_metric, agent_run: bad_run, composite_score: 0.0)
      end

      exhausted_run = create(:agent_run, status: "failed", project: project, goal: agent_run.goal,
        error_message: "All providers exhausted: claude_code")
      create(:quality_metric, agent_run: exhausted_run, composite_score: 0.0)

      low_run = create(:agent_run, :completed, project: project)
      create(:quality_metric, agent_run: low_run, composite_score: 0.2)

      described_class.call(agent_run: agent_run)

      expect(project.reload.quality_paused?).to be false
    end

    it "includes failed runs with agent-level errors in scoring" do
      agent_error_run = create(:agent_run, status: "failed", project: project, goal: agent_run.goal,
        error_message: "Agent exited with code 1")
      create(:quality_metric, agent_run: agent_error_run, composite_score: 0.0)

      create_quality_metrics(project, scores: [ 0.0, 0.1, 0.2 ], prompt_version: prompt_version)

      described_class.call(agent_run: agent_run)

      expect(project.reload.quality_paused?).to be false
      expect(project.quality_recovery_actions.last.action_type).to eq("prompt_evolution")
    end

    it "starts targeted prompt evolution when rolling average falls below threshold" do
      create_quality_metrics(project, scores: [ 0.2, 0.3, 0.1, 0.4, 0.3 ], prompt_version: prompt_version)

      expect {
        described_class.call(agent_run: agent_run)
      }.to have_enqueued_job(PromptEvolutionJob).with(
        project_id: project.id,
        prompt_id: prompt.id,
        recovery_action_id: kind_of(Integer),
        failure_only: true,
        metric_type: "composite_score",
        threshold: 0.5,
        goal_type: agent_run.goal
      )

      project.reload
      expect(project.quality_paused?).to be false
      action = project.quality_recovery_actions.last
      expect(action.action_type).to eq("prompt_evolution")
      expect(action.status).to eq("executing")
      expect(action.executed_at).to be_nil
      expect(action.quality_before).to eq(0.26)
    end

    it "does not evaluate prompt evolution before the evolution test starts" do
      create(:quality_recovery_action, :prompt_evolution, :executing,
        project: project, executed_at: nil, quality_before: 0.3)
      create(:llm_model, tier: "mid")
      create_quality_metrics(project, scores: Array.new(QualityThreshold::DEFAULT_WINDOW_SIZE, 0.2))

      described_class.call(agent_run: agent_run)

      expect(project.reload.model_preferences["quality_recovery_min_tier"]).to be_nil
      expect(project.quality_recovery_actions.last.action_type).to eq("prompt_evolution")
    end

    it "starts quality-triggered model escalation before pausing" do
      mid_model = create(:llm_model, tier: "mid", capability_score: 7.0)
      create(:llm_model, tier: "high", capability_score: 10.0)
      create(:model_selection, agent_run: agent_run, llm_model: mid_model, tier: "mid")
      create_quality_metrics(project, scores: [ 0.2, 0.3, 0.1, 0.4, 0.3 ])

      described_class.call(agent_run: agent_run)

      project.reload
      escalation = project.model_preferences["quality_triggered_escalation"]
      expect(project.quality_paused?).to be false
      expect(escalation).to include(
        "status" => "active",
        "trigger" => "quality_drop",
        "from_tier" => "mid",
        "to_tier" => "high"
      )
      expect(project.quality_recovery_actions.last.parameters).to include("trigger" => "quality_drop")
    end

    it "requests prompt evolution when escalated runs do not recover quality" do
      allow(PromptEvolutionJob).to receive(:perform_later)
      create(:llm_model, tier: "high", capability_score: 10.0)
      request_model_escalation_recovery(project)
      create_quality_metrics(project, scores: [ 0.2, 0.3, 0.1, 0.4, 0.3 ], prompt_version: prompt_version)
      create_escalated_metrics(project, scores: [ 0.2, 0.3, 0.1 ])

      described_class.call(agent_run: agent_run)

      escalation = project.reload.model_preferences["quality_triggered_escalation"]
      expect(project.quality_paused?).to be false
      expect(escalation).to include("status" => "prompt_evolution_requested")
      expect(PromptEvolutionJob).to have_received(:perform_later).with(prompt_id: prompt.id, project_id: project.id)
    end

    it "keeps deferring pause without re-requesting prompt evolution while it is pending" do
      allow(PromptEvolutionJob).to receive(:perform_later)
      create(:llm_model, tier: "high", capability_score: 10.0)
      project.update!(model_preferences: {
        "quality_triggered_escalation" => {
          "status" => "prompt_evolution_requested",
          "trigger" => "quality_drop",
          "goal" => agent_run.goal,
          "from_tier" => "mid",
          "to_tier" => "high",
          "started_at" => 1.day.ago.iso8601,
          "threshold" => 0.5,
          "evaluation_window" => 3
        }
      })
      create_quality_metrics(project, scores: [ 0.2, 0.3, 0.1, 0.4, 0.3 ])
      create_escalated_metrics(project, scores: [ 0.2, 0.3, 0.1 ])

      described_class.call(agent_run: agent_run)

      expect(project.reload.quality_paused?).to be false
      expect(PromptEvolutionJob).not_to have_received(:perform_later)
    end

    it "pauses after the prompt evolution recovery window is exhausted" do
      create(:llm_model, tier: "high", capability_score: 10.0)
      request_prompt_evolution_recovery(project)
      create_quality_metrics(project, scores: [ 0.2, 0.3, 0.1, 0.4, 0.3 ])
      create_escalated_metrics(project, scores: [ 0.2, 0.3, 0.1 ])

      described_class.call(agent_run: agent_run)

      escalation = project.reload.model_preferences["quality_triggered_escalation"]
      expect(project.quality_paused?).to be true
      expect(escalation).to include(
        "status" => "exhausted",
        "prompt_evolution_average" => 0.2,
        "prompt_evolution_sample_size" => 3
      )
    end

    it "persists a recovered terminal state when escalated runs recover quality" do
      create(:llm_model, tier: "high", capability_score: 10.0)
      request_model_escalation_recovery(project)
      create_quality_metrics(project, scores: [ 0.2, 0.3, 0.1, 0.4, 0.3 ])
      create_escalated_metrics(project, scores: [ 0.8, 0.7, 0.9 ])

      described_class.call(agent_run: agent_run)

      escalation = project.reload.model_preferences["quality_triggered_escalation"]
      expect(project.quality_paused?).to be false
      expect(escalation).to include(
        "status" => "recovered",
        "recovered_via" => "model_escalation",
        "recovered_average" => 0.8,
        "recovered_sample_size" => 3
      )
      expect(QualityRecovery::ModelEscalation.active?(project)).to be false
    end

    it "persists a recovered terminal state when prompt evolution recovers quality" do
      create(:llm_model, tier: "high", capability_score: 10.0)
      request_prompt_evolution_recovery(project)
      create_quality_metrics(project, scores: [ 0.2, 0.3, 0.1, 0.4, 0.3 ])
      create_escalated_metrics(project, scores: [ 0.8, 0.7, 0.9 ])

      described_class.call(agent_run: agent_run)

      escalation = project.reload.model_preferences["quality_triggered_escalation"]
      expect(project.quality_paused?).to be false
      expect(escalation).to include(
        "status" => "recovered",
        "recovered_via" => "prompt_evolution",
        "recovered_average" => 0.8,
        "recovered_sample_size" => 3
      )
      expect(QualityRecovery::ModelEscalation.active?(project)).to be false
    end

    it "caps the rolling window to the latest DEFAULT_WINDOW_SIZE eligible runs" do
      # 10 old low-scoring runs followed by 5 newer high-scoring runs.
      # With window_size=10: latest 10 include 5 * 0.7 + 5 * 0.0 -> avg=0.35 < 0.5 -> recovery
      # With window_size=5:  latest 5 are all 0.7                  -> avg=0.7  > 0.5 -> no recovery
      create_quality_metrics(project, scores: Array.new(10, 0.0), prompt_version: prompt_version)
      create_quality_metrics(project, scores: Array.new(5, 0.7), prompt_version: prompt_version)

      described_class.call(agent_run: agent_run)

      project.reload
      expect(project.quality_paused?).to be false
      expect(project.quality_recovery_actions.last.parameters["recent_scores"].size).to eq(10)
    end

    it "starts recovery when a metric-specific threshold is breached" do
      create(:quality_threshold, account: project.account, metric_type: "lint_clean", goal_type: "create_pr")
      create_metric_scores(project, metric_type: "lint_clean", scores: [ 0.0, 1.0, 0.0, 0.0, 0.0 ], prompt_version: prompt_version)

      described_class.call(agent_run: agent_run)

      project.reload
      expect(project.quality_paused?).to be false
      expect(project.quality_recovery_actions.last.parameters["metric_type"]).to eq("lint_clean")
    end

    it "evaluates each metric threshold against its own latest samples" do
      create(:quality_threshold,
        account: project.account,
        metric_type: "reaction_score",
        goal_type: "create_pr",
        min_value: 0.5)
      create_metric_scores(project, metric_type: "reaction_score", scores: [ 0.0, 0.1, 0.2 ], prompt_version: prompt_version)
      create_quality_metrics(project, scores: Array.new(5, 0.8), prompt_version: prompt_version)

      described_class.call(agent_run: agent_run)

      project.reload
      expect(project.quality_paused?).to be false
      expect(project.quality_recovery_actions.last.parameters["metric_type"]).to eq("reaction_score")
    end

    it "logs when a breach triggers recovery" do
      create_quality_metrics(project, scores: [ 0.2, 0.3, 0.1, 0.4, 0.3 ], prompt_version: prompt_version)

      agent_run
      allow(Rails.logger).to receive(:info).and_call_original

      described_class.call(agent_run: agent_run)

      expect(Rails.logger).to have_received(:info).with(hash_including(
        message: "quality_recovery.prompt_evolution_queued",
        project_id: project.id
      ))
      expect(Rails.logger).to have_received(:info).with(hash_including(
        message: "quality_recovery.breach_detected",
        project_id: project.id
      ))
    end

    it "escalates model tier when prompt evolution does not recover quality" do
      create(:quality_recovery_action, :prompt_evolution, :evaluated,
        project: project, executed_at: 2.hours.ago, quality_before: 0.3, quality_after: 0.3)
      create(:llm_model, tier: "mid")
      create_quality_metrics(project, scores: [ 0.2, 0.3, 0.1, 0.4, 0.3 ])

      described_class.call(agent_run: agent_run)

      project.reload
      expect(project.quality_paused?).to be false
      expect(project.model_preferences["quality_recovery_min_tier"]).to eq("mid")
      expect(project.quality_recovery_actions.last.action_type).to eq("model_escalation")
    end

    it "pauses when escalation target exceeds max_tier preference" do
      create(:quality_recovery_action, :prompt_evolution, :evaluated,
        project: project, executed_at: 2.hours.ago, quality_before: 0.3, quality_after: 0.3)
      create(:llm_model, tier: "mid")
      project.update!(model_preferences: { "max_tier" => "low" })
      create_quality_metrics(project, scores: [ 0.2, 0.3, 0.1, 0.4, 0.3 ])

      described_class.call(agent_run: agent_run)

      project.reload
      expect(project.quality_paused?).to be true
      expect(project.model_preferences["quality_recovery_min_tier"]).to be_nil
    end

    it "still escalates the model after repeated prompt evolution attempts hit the daily cap" do
      3.times do |attempt|
        create(:quality_recovery_action, :prompt_evolution, :evaluated,
          project: project,
          created_at: (attempt + 1).hours.ago,
          executed_at: (attempt + 1).hours.ago,
          quality_before: 0.3,
          quality_after: 0.3)
      end
      create(:llm_model, tier: "mid")
      create_quality_metrics(project, scores: [ 0.2, 0.3, 0.1, 0.4, 0.3 ])

      described_class.call(agent_run: agent_run)

      project.reload
      expect(project.quality_paused?).to be false
      expect(project.model_preferences["quality_recovery_min_tier"]).to eq("mid")
      expect(project.quality_recovery_actions.last.action_type).to eq("model_escalation")
    end

    it "evaluates recovery against the breached metric rather than composite score" do
      create(:quality_threshold,
        account: project.account,
        metric_type: "reaction_score",
        goal_type: "create_pr",
        min_value: 0.5)
      action = create(:quality_recovery_action, :prompt_evolution, :executed,
        project: project, executed_at: 2.hours.ago, quality_before: 0.3)
      create(:llm_model, tier: "mid")
      create_metric_scores(project,
        metric_type: "reaction_score",
        scores: Array.new(QualityThreshold::DEFAULT_WINDOW_SIZE, 0.2))

      described_class.call(agent_run: agent_run)

      expect(action.reload.quality_after).to eq(0.2)
      expect(project.reload.model_preferences["quality_recovery_min_tier"]).to eq("mid")
      expect(project.quality_recovery_actions.last.action_type).to eq("model_escalation")
    end

    it "pauses only after prompt evolution and model escalation fail" do
      create(:quality_recovery_action, :prompt_evolution, :evaluated,
        project: project, executed_at: 3.hours.ago, quality_before: 0.3, quality_after: 0.3)
      create(:quality_recovery_action, :model_escalation, :evaluated,
        project: project, executed_at: 2.hours.ago, quality_before: 0.3, quality_after: 0.3)
      create_quality_metrics(project, scores: [ 0.2, 0.3, 0.1, 0.4, 0.3 ])

      described_class.call(agent_run: agent_run)

      project.reload
      expect(project.quality_paused?).to be true
      expect(project.quality_pause_events.pauses.count).to eq(1)
      expect(project.quality_recovery_actions.last.action_type).to eq("final_pause")
      notification = Notification.find_by(account: project.account, source: "quality_recovery", subject: project)
      expect(notification).to be_present
      expect(notification.severity).to eq("error")
      expect(notification.metadata["diagnosis"]).to include("metric_type" => "composite_score")
    end

    it "does not enqueue prompt evolution when the project is not paused" do
      create_quality_metrics(project, scores: [ 0.8, 0.7, 0.9, 0.6, 0.8 ])

      expect {
        described_class.call(agent_run: agent_run)
      }.not_to have_enqueued_job(PromptEvolutionJob)
    end

    describe "grace period after manual resume" do
      it "skips quality pause check within grace period after resume" do
        create_quality_metrics(project, scores: [ 0.2, 0.3, 0.1, 0.4, 0.3 ])

        project.update!(quality_paused_at: Time.current)
        project.quality_resume!

        described_class.call(agent_run: agent_run)

        expect(project.reload.quality_paused?).to be false
      end

      it "does not pause when fewer than DEFAULT_WINDOW_SIZE samples exist after resume" do
        create(:quality_pause_event, :resumed, project: project, created_at: 1.hour.ago)
        create_quality_metrics(project, scores: [ 0.1 ] * 5)

        described_class.call(agent_run: agent_run)

        expect(project.reload.quality_paused?).to be false
      end

      it "resumes quality pause checks after DEFAULT_WINDOW_SIZE samples exist" do
        create(:quality_pause_event, :resumed, project: project, created_at: 1.hour.ago)
        create_quality_metrics(project, scores: [ 0.1 ] * (QualityThreshold::DEFAULT_WINDOW_SIZE + 3), prompt_version: prompt_version)

        described_class.call(agent_run: agent_run)

        expect(project.reload.quality_paused?).to be false
        expect(project.quality_recovery_actions.last.action_type).to eq("prompt_evolution")
      end

      it "does not count excluded statuses toward grace period window" do
        create(:quality_pause_event, :resumed, project: project, created_at: 1.hour.ago)
        create_quality_metrics(project, scores: [ 0.1 ] * (QualityThreshold::DEFAULT_WINDOW_SIZE - 2))

        AgentRun::QUALITY_EXCLUDED_STATUSES.each do |status|
          run = create(:agent_run, status: status, project: project,
            completed_at: 30.minutes.ago, goal: agent_run.goal)
          create(:quality_metric, agent_run: run, composite_score: 0.0)
        end

        described_class.call(agent_run: agent_run)

        expect(project.reload.quality_paused?).to be false
      end

      it "applies grace period regardless of score quality" do
        create(:quality_pause_event, :resumed, project: project, created_at: 1.hour.ago)
        create_quality_metrics(project, scores: [ 0.0 ] * 4)

        described_class.call(agent_run: agent_run)

        expect(project.reload.quality_paused?).to be false
      end

      it "does not count runs of a different goal toward grace period window" do
        create(:quality_pause_event, :resumed, project: project, created_at: 1.hour.ago)

        # Enough different-goal runs that counting them would exceed the window (3 matching + 8 other > 10)
        (QualityThreshold::DEFAULT_WINDOW_SIZE - 2).times do
          run = create(:agent_run, :completed, :create_issue_goal, project: project)
          create(:quality_metric, agent_run: run, composite_score: 0.1)
        end

        create_quality_metrics(project, scores: [ 0.1 ] * 3)

        described_class.call(agent_run: agent_run)

        expect(project.reload.quality_paused?).to be false
      end

      it "does not expire grace period until the breached metric has a full post-resume window" do
        create(:quality_threshold,
          account: project.account,
          metric_type: "reaction_score",
          goal_type: "create_pr",
          min_value: 0.5)
        create_metric_scores(project,
          metric_type: "reaction_score",
          scores: [ 0.1 ] * 5,
          completed_at: 2.hours.ago)
        create(:quality_pause_event, :resumed, project: project, created_at: 1.hour.ago)
        create_quality_metrics(project, scores: [ 0.9 ] * 5)
        create_metric_scores(project, metric_type: "reaction_score", scores: [ 0.1 ] * 2)

        described_class.call(agent_run: agent_run)

        expect(project.reload.quality_paused?).to be false
      end

      it "expires grace period when the breached metric has a full post-resume window" do
        create(:quality_threshold,
          account: project.account,
          metric_type: "reaction_score",
          goal_type: "create_pr",
          min_value: 0.5)
        create(:quality_pause_event, :resumed, project: project, created_at: 1.hour.ago)
        create_metric_scores(project,
          metric_type: "reaction_score",
          scores: [ 0.1 ] * QualityThreshold::DEFAULT_WINDOW_SIZE,
          prompt_version: prompt_version)

        described_class.call(agent_run: agent_run)

        expect(project.reload.quality_paused?).to be false
        expect(project.quality_recovery_actions.last.parameters["metric_type"]).to eq("reaction_score")
      end

      it "logs info when grace period is active" do
        create(:quality_pause_event, :resumed, project: project, created_at: 1.hour.ago)
        create_quality_metrics(project, scores: [ 0.1 ] * 3)

        expect(Rails.logger).to receive(:info).with(hash_including(
          message: "quality_pause.grace_period_active",
          project_id: project.id,
          goal: agent_run.goal
        ))

        described_class.call(agent_run: agent_run)
      end
    end
  end

  private

  def create_quality_metrics(project, scores:, prompt_version: nil)
    scores.each do |score|
      run = create(:agent_run, :completed, project: project, prompt_version: prompt_version, issue: nil, custom_prompt: "quality metric fixture")
      create(:quality_metric, agent_run: run, prompt_version: prompt_version, composite_score: score)
    end
  end

  def create_metric_scores(project, metric_type:, scores:, completed_at: Time.current, prompt_version: nil)
    scores.each do |score|
      run = create(:agent_run, :completed, project: project, completed_at: completed_at, prompt_version: prompt_version, issue: nil, custom_prompt: "quality metric fixture")
      create(:quality_metric, agent_run: run, prompt_version: prompt_version, composite_score: 0.8, scores: { metric_type => score })
    end
  end

  def create_escalated_metrics(project, scores:)
    high_model = LlmModel.find_by!(tier: "high")

    scores.each do |score|
      run = create(:agent_run, :completed, project: project, goal: agent_run.goal, issue: nil, custom_prompt: "quality metric fixture")
      create(:model_selection,
        agent_run: run,
        llm_model: high_model,
        selector_type: "quality_escalation",
        tier: "high")
      create(:quality_metric, agent_run: run, composite_score: score)
    end
  end

  def request_prompt_evolution_recovery(project)
    project.update!(model_preferences: {
      "quality_triggered_escalation" => {
        "status" => "prompt_evolution_requested",
        "trigger" => "quality_drop",
        "goal" => agent_run.goal,
        "from_tier" => "mid",
        "to_tier" => "high",
        "started_at" => 2.days.ago.iso8601,
        "prompt_evolution_requested_at" => 1.day.ago.iso8601,
        "threshold" => 0.5,
        "evaluation_window" => 3
      }
    })
  end

  def request_model_escalation_recovery(project)
    project.update!(model_preferences: {
      "quality_triggered_escalation" => {
        "status" => "active",
        "trigger" => "quality_drop",
        "goal" => agent_run.goal,
        "from_tier" => "mid",
        "to_tier" => "high",
        "started_at" => 1.day.ago.iso8601,
        "threshold" => 0.5,
        "evaluation_window" => 3
      }
    })
  end
end
