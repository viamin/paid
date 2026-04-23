# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityPause::Check do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :completed, project: project) }

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

      create_quality_metrics(project, scores: [ 0.0, 0.1, 0.2 ])

      described_class.call(agent_run: agent_run)

      expect(project.reload.quality_paused?).to be true
    end

    it "pauses the project when rolling average falls below threshold" do
      create_quality_metrics(project, scores: [ 0.2, 0.3, 0.1, 0.4, 0.3 ])
      described_class.call(agent_run: agent_run)

      project.reload
      expect(project.quality_paused?).to be true
      expect(project.quality_pause_events.pauses.count).to eq(1)

      event = project.quality_pause_events.last
      expect(event.agent_run).to eq(agent_run)
      expect(event.threshold).to eq(0.5)
    end

    it "caps the rolling window to the latest DEFAULT_WINDOW_SIZE eligible runs" do
      # 10 old low-scoring runs followed by 5 newer high-scoring runs.
      # With window_size=10: latest 10 include 5 * 0.7 + 5 * 0.0 -> avg=0.35 < 0.5 -> paused
      # With window_size=5:  latest 5 are all 0.7                  -> avg=0.7  > 0.5 -> not paused
      create_quality_metrics(project, scores: Array.new(10, 0.0))
      create_quality_metrics(project, scores: Array.new(5, 0.7))

      described_class.call(agent_run: agent_run)

      project.reload
      expect(project.quality_paused?).to be true
      expect(project.quality_pause_metadata["sample_size"]).to eq(10)
    end

    it "pauses the project when a metric-specific threshold is breached" do
      create(:quality_threshold, account: project.account, metric_type: "lint_clean", goal_type: "create_pr")
      create_metric_scores(project, metric_type: "lint_clean", scores: [ 0.0, 1.0, 0.0, 0.0, 0.0 ])

      described_class.call(agent_run: agent_run)

      project.reload
      expect(project.quality_paused?).to be true
      expect(project.quality_pause_metadata["metric_type"]).to eq("lint_clean")
    end

    it "evaluates each metric threshold against its own latest samples" do
      create(:quality_threshold,
        account: project.account,
        metric_type: "reaction_score",
        goal_type: "create_pr",
        min_value: 0.5)
      create_metric_scores(project, metric_type: "reaction_score", scores: [ 0.0, 0.1, 0.2 ])
      create_quality_metrics(project, scores: Array.new(15, 0.8))

      described_class.call(agent_run: agent_run)

      project.reload
      expect(project.quality_paused?).to be true
      expect(project.quality_pause_metadata["metric_type"]).to eq("reaction_score")
    end

    it "logs a warning when pausing" do
      create_quality_metrics(project, scores: [ 0.2, 0.3, 0.1, 0.4, 0.3 ])

      expect(Rails.logger).to receive(:warn).with(hash_including(
        message: "quality_pause.project_paused",
        project_id: project.id
      ))

      described_class.call(agent_run: agent_run)
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
        create_quality_metrics(project, scores: [ 0.1 ] * (QualityThreshold::DEFAULT_WINDOW_SIZE + 3))

        described_class.call(agent_run: agent_run)

        expect(project.reload.quality_paused?).to be true
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
          scores: [ 0.1 ] * QualityThreshold::DEFAULT_WINDOW_SIZE)

        described_class.call(agent_run: agent_run)

        expect(project.reload.quality_paused?).to be true
        expect(project.quality_pause_metadata["metric_type"]).to eq("reaction_score")
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

  def create_quality_metrics(project, scores:)
    scores.each do |score|
      run = create(:agent_run, :completed, project: project)
      create(:quality_metric, agent_run: run, composite_score: score)
    end
  end

  def create_metric_scores(project, metric_type:, scores:, completed_at: Time.current)
    scores.each do |score|
      run = create(:agent_run, :completed, project: project, completed_at: completed_at)
      create(:quality_metric, agent_run: run, composite_score: 0.8, scores: { metric_type => score })
    end
  end
end
