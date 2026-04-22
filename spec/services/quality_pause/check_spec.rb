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

    it "excludes timeout, auth_expired, and rate_limited runs from scoring" do
      good_run = create(:agent_run, :completed, project: project)
      create(:quality_metric, agent_run: good_run, composite_score: 0.9)

      excluded_statuses = %w[timeout auth_expired rate_limited]
      excluded_statuses.each do |status|
        bad_run = create(:agent_run, status: status, project: project, goal: agent_run.goal)
        create(:quality_metric, agent_run: bad_run, composite_score: 0.0)
      end

      low_run = create(:agent_run, :completed, project: project)
      create(:quality_metric, agent_run: low_run, composite_score: 0.2)

      described_class.call(agent_run: agent_run)

      expect(project.reload.quality_paused?).to be false
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
  end

  private

  def create_quality_metrics(project, scores:)
    scores.each do |score|
      run = create(:agent_run, :completed, project: project)
      create(:quality_metric, agent_run: run, composite_score: score)
    end
  end

  def create_metric_scores(project, metric_type:, scores:)
    scores.each do |score|
      run = create(:agent_run, :completed, project: project)
      create(:quality_metric, agent_run: run, composite_score: 0.8, scores: { metric_type => score })
    end
  end
end
