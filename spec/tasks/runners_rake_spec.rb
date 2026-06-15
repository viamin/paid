# frozen_string_literal: true

require "rails_helper"
require "rake"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "runners:reset_backoff" do
  let(:task) { Rake::Task["runners:reset_backoff"] }
  let(:project) { create(:project) }
  let!(:open_circuit) { create(:runner_state, :circuit_open) }
  let!(:rate_limited_run) { create(:agent_run, :rate_limited, project: project, stale_requeue_count: 4, stale_skip_count: 2) }
  let!(:parked_job) do
    GoodJob::Job.create!(
      job_class: "Issues::ReenqueueEligibleJob",
      queue_name: "default",
      scheduled_at: 3.days.from_now,
      serialized_params: {}
    )
  end

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("runners:reset_backoff")
    task.reenable
  end

  after { ENV.delete("DRY_RUN") }

  context "with DRY_RUN (default)" do
    it "reports counts without writing changes" do
      expect { task.invoke }.to output(/DRY RUN/).to_stdout

      expect(open_circuit.reload.circuit_state).to eq("open")
      expect(rate_limited_run.reload.stale_requeue_count).to eq(4)
      expect(parked_job.reload.scheduled_at).to be > 1.day.from_now
    end
  end

  context "with DRY_RUN=false" do
    before { ENV["DRY_RUN"] = "false" }

    it "closes open runner circuits" do
      task.invoke
      expect(open_circuit.reload.circuit_state).to eq("closed")
      expect(open_circuit.failure_count).to eq(0)
    end

    it "makes rate-limited runs due now and clears their requeue/skip counters" do
      task.invoke
      rate_limited_run.reload
      expect(rate_limited_run.rate_limited_until).to be < Time.current
      expect(rate_limited_run.stale_requeue_count).to eq(0)
      expect(rate_limited_run.stale_skip_count).to eq(0)
    end

    it "releases parked auto-pick re-enqueue jobs to run now" do
      task.invoke
      expect(parked_job.reload.scheduled_at).to be <= Time.current
    end
  end
end
# rubocop:enable RSpec/DescribeClass
