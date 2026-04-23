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

    it "starts prompt evolution when rolling average falls below threshold" do
      create_quality_metrics(project, scores: [ 0.2, 0.3, 0.1, 0.4, 0.3 ], prompt_version: prompt_version)

      expect {
        described_class.call(agent_run: agent_run)
      }.to have_enqueued_job(PromptEvolutionJob).with(
        project_id: project.id,
        prompt_id: prompt.id,
        recovery_action_id: kind_of(Integer)
      )

      project.reload
      expect(project.quality_paused?).to be false
      action = project.quality_recovery_actions.last
      expect(action.action_type).to eq("prompt_evolution")
      expect(action.quality_before).to eq(0.26)
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
      create_quality_metrics(project, scores: Array.new(15, 0.8), prompt_version: prompt_version)

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

        (QualityThreshold::DEFAULT_WINDOW_SIZE + 3).times do
          run = create(:agent_run, :completed, project: project, goal: "enhance_issue")
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
        create_quality_metrics(project, scores: [ 0.9 ] * QualityThreshold::DEFAULT_WINDOW_SIZE)
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
      run = create(:agent_run, :completed, project: project, prompt_version: prompt_version)
      create(:quality_metric, agent_run: run, prompt_version: prompt_version, composite_score: score)
    end
  end

  def create_metric_scores(project, metric_type:, scores:, completed_at: Time.current, prompt_version: nil)
    scores.each do |score|
      run = create(:agent_run, :completed, project: project, completed_at: completed_at, prompt_version: prompt_version)
      create(:quality_metric, agent_run: run, prompt_version: prompt_version, composite_score: 0.8, scores: { metric_type => score })
    end
  end
end
