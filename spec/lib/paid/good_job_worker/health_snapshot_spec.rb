# frozen_string_literal: true

require "rails_helper"
require_relative "../../../../lib/paid/good_job_worker"
require_relative "../../../../lib/paid/good_job_worker/health_snapshot"

# @spec RAILS-CONTROL-PLANE-030
RSpec.describe Paid::GoodJobWorker::HealthSnapshot do
  let(:pid) { 999_331 }
  let(:pools) { [ { "queues" => "default", "available_threads" => 1, "total_executions_count" => 0 } ] }
  let!(:process_record) { GoodJob::Process.create!(state: { "pid" => pid, "schedulers" => pools }) }
  let(:scheduler) { instance_double(GoodJob::Scheduler, running?: true) }
  let(:snapshot) { described_class.new(pid:, schedulers: [ scheduler ]).call }

  def enqueue_job(queue: "default", **attributes)
    GoodJob::Job.create!(active_job_id: SecureRandom.uuid, queue_name: queue,
      scheduled_at: 1.minute.ago, serialized_params: { "job_class" => "HealthSnapshotFixtureJob" }, **attributes)
  end

  it "counts eligible work against the pool that owns its queue" do
    process_record.update!(state: { "pid" => pid, "schedulers" => [
      { "queues" => "shadow_evaluation", "available_threads" => 0 }, pools.first
    ] })
    enqueue_job(queue: "shadow_evaluation")

    observed = snapshot.fetch(:process).fetch(:schedulers)

    expect(observed.map { |pool| pool.fetch("runnable_jobs") }).to eq([ 1, 0 ])
    monitor = Paid::GoodJobWorker::HealthMonitor.new(progress_timeout: 30)
    expect(monitor.observe(snapshot)).to be_healthy
    expect(monitor.observe(snapshot, now: Time.current + 31)).to be_healthy
  end

  it "ignores work excluded by the scheduler queue expression" do
    enqueue_job(queue: "shadow_evaluation")

    expect(snapshot.fetch(:runnable_jobs)).to eq(1)
    expect(snapshot.fetch(:process).fetch(:schedulers).sole.fetch("runnable_jobs")).to eq(0)
  end

  it "uses GoodJob ordered and excluded queue expressions" do
    process_record.update!(state: { "pid" => pid, "schedulers" => [
      pools.first.merge("queues" => "+default,maintenance"), pools.first.merge("queues" => "-shadow_evaluation")
    ] })
    %w[default maintenance shadow_evaluation].each { |queue| enqueue_job(queue:) }

    expect(snapshot.fetch(:process).fetch(:schedulers).map { |pool| pool.fetch("runnable_jobs") }).to eq([ 2, 2 ])
  end

  it "excludes paused queues, job classes, and labels using GoodJob eligibility" do
    allow(GoodJob.configuration).to receive(:enable_pauses).and_return(true)
    GoodJob::Setting.pause(queue: "default")
    enqueue_job

    expect(snapshot.fetch(:runnable_jobs)).to eq(0)
  end

  it "excludes a paused job class without pausing its queue" do
    allow(GoodJob.configuration).to receive(:enable_pauses).and_return(true)
    GoodJob::Setting.pause(job_class: "HealthSnapshotFixtureJob")
    enqueue_job

    expect(snapshot.fetch(:runnable_jobs)).to eq(0)
  end

  it "excludes a paused job label without pausing its queue" do
    allow(GoodJob.configuration).to receive(:enable_pauses).and_return(true)
    GoodJob::Setting.pause(label: "health-test")
    enqueue_job(labels: [ "health-test" ])

    expect(snapshot.fetch(:runnable_jobs)).to eq(0)
  end

  it "excludes future, finished, and persistently claimed jobs" do
    enqueue_job(scheduled_at: 1.minute.from_now)
    enqueue_job(finished_at: Time.current)
    enqueue_job(locked_by_id: process_record.id, locked_at: Time.current)

    expect(snapshot.fetch(:runnable_jobs)).to eq(0)
  end

  it "excludes a job whose GoodJob advisory ownership is still held" do
    job = enqueue_job

    job.advisory_lock do
      expect(snapshot.fetch(:runnable_jobs)).to eq(0)
    end
  end

  it "reports lost database visibility for bounded missing-heartbeat detection" do
    allow(GoodJob::Process).to receive(:where).and_raise(ActiveRecord::ConnectionTimeoutError)
    monitor = Paid::GoodJobWorker::HealthMonitor.new(heartbeat_timeout: 30)

    expect(snapshot[:process]).to be_nil
    expect(monitor.observe(snapshot)).to be_healthy
    expect(monitor.observe(snapshot, now: Time.current + 31)).to have_attributes(reason: :missing_process_heartbeat)
  end
end
