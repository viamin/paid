# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScheduledMutationSweepJob do
  let(:job) { described_class.new }
  let(:account) { create(:account) }

  describe "#perform" do
    before do
      allow(MutationSweeps::Run).to receive(:call)
      allow(described_class).to receive(:perform_later)
    end

    it "runs the sweep for eligible ruby projects only" do
      eligible_project = create(:project, account: account)
      create(:pre_commit_requirement, :mutation_test, project: eligible_project, account: account, name: "mutant-eligible")

      disabled_project = create(:project, account: account)
      create(:pre_commit_requirement, :mutation_test, :disabled,
        project: disabled_project, account: account, name: "mutant-disabled")

      non_ruby_project = create(:project, account: account)
      create(:pre_commit_requirement, :mutation_test, project: non_ruby_project, account: account, name: "mutant-js")
      non_ruby_project.define_singleton_method(:detected_language) { "javascript" }

      job.perform(sweep_date: "2026-05-27")

      expect(MutationSweeps::Run).to have_received(:call).with(project: eligible_project, sweep_date: Date.new(2026, 5, 27)).once
      expect(MutationSweeps::Run).not_to have_received(:call).with(hash_including(project: disabled_project))
      expect(MutationSweeps::Run).not_to have_received(:call).with(hash_including(project: non_ruby_project))
    end

    it "skips projects already swept on the same date" do
      project = create(:project, account: account)
      create(:pre_commit_requirement, :mutation_test, project: project, account: account, name: "mutant")
      metric_run = create(:agent_run, :completed, project: project)
      create(:quality_metric,
        agent_run: metric_run,
        source: QualityMetric::SCHEDULED_MUTATION_SWEEP_SOURCE,
        mutation_kill_rate: 0.8,
        scores: { "mutation_kill_rate" => 0.8 },
        created_at: Time.zone.local(2026, 5, 27, 12))

      job.perform(sweep_date: "2026-05-27")

      expect(MutationSweeps::Run).not_to have_received(:call)
    end

    it "scopes the sweep window to the configured zone day, not the UTC day" do
      project = create(:project, account: account)
      create(:pre_commit_requirement, :mutation_test, project: project, account: account, name: "mutant")
      metric_run = create(:agent_run, :completed, project: project)
      # 2026-05-26 20:30 Pacific falls on 2026-05-27 in UTC; a UTC-day lookup
      # would wrongly treat the project as already swept for 2026-05-27.
      create(:quality_metric,
        agent_run: metric_run,
        source: QualityMetric::SCHEDULED_MUTATION_SWEEP_SOURCE,
        mutation_kill_rate: 0.8,
        scores: { "mutation_kill_rate" => 0.8 },
        created_at: Time.zone.local(2026, 5, 26, 20, 30))

      job.perform(sweep_date: "2026-05-27")

      expect(MutationSweeps::Run).to have_received(:call).with(project: project, sweep_date: Date.new(2026, 5, 27)).once
    end

    it "treats failed sweep markers as already attempted for the date" do
      failed_project = create(:project, account: account)
      next_project = create(:project, account: account)
      create(:pre_commit_requirement, :mutation_test, project: failed_project, account: account, name: "mutant-failed")
      create(:pre_commit_requirement, :mutation_test, project: next_project, account: account, name: "mutant-next")

      failed_run = create(:agent_run, :failed, project: failed_project)
      create(:quality_metric,
        agent_run: failed_run,
        source: QualityMetric::SCHEDULED_MUTATION_SWEEP_SOURCE,
        mutation_kill_rate: nil,
        scores: {},
        created_at: Time.zone.local(2026, 5, 27, 12))

      job.perform(sweep_date: "2026-05-27")

      expect(MutationSweeps::Run).to have_received(:call).with(project: next_project, sweep_date: Date.new(2026, 5, 27)).once
      expect(MutationSweeps::Run).not_to have_received(:call).with(hash_including(project: failed_project))
    end

    it "queues a follow-up job when another eligible project remains" do
      first_project = create(:project, account: account)
      second_project = create(:project, account: account)
      create(:pre_commit_requirement, :mutation_test, project: first_project, account: account, name: "mutant-1")
      create(:pre_commit_requirement, :mutation_test, project: second_project, account: account, name: "mutant-2")

      job.perform(sweep_date: "2026-05-27")

      expect(described_class).to have_received(:perform_later).with(sweep_date: "2026-05-27", attempted_project_ids: [ first_project.id ])
    end

    it "excludes a failed project from the next job even before a marker exists" do
      failing_project = create(:project, account: account)
      remaining_project = create(:project, account: account)
      create(:pre_commit_requirement, :mutation_test, project: failing_project, account: account, name: "mutant-fail")
      create(:pre_commit_requirement, :mutation_test, project: remaining_project, account: account, name: "mutant-next")

      allow(MutationSweeps::Run).to receive(:call).with(project: failing_project, sweep_date: Date.new(2026, 5, 27)).and_raise(StandardError, "boom")

      job.perform(sweep_date: "2026-05-27")

      expect(described_class).to have_received(:perform_later).with(sweep_date: "2026-05-27", attempted_project_ids: [ failing_project.id ])
    end
  end
end
