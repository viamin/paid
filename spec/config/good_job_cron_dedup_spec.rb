# frozen_string_literal: true

require "rails_helper"

# GoodJob 4.x makes the cron scheduler safe to run on multiple hosts: every
# cron enqueue is stamped with a (cron_key, cron_at) pair protected by the
# unique index `index_good_jobs_on_cron_key_and_cron_at_cond`. This spec
# simulates two hosts firing the same cron tick and asserts only one job is
# enqueued. @spec RAILS-CONTROL-PLANE-007
class GoodJobCronDedupProbeJob < ActiveJob::Base
  queue_as :default

  def perform; end
end

RSpec.describe GoodJob do
  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :good_job
    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
  end

  it "enqueues exactly one job when two hosts fire the same cron tick" do
    entry = GoodJob::CronEntry.new(
      key: "good_job_cron_dedup_probe",
      cron: "0 0 * * *",
      class: "GoodJobCronDedupProbeJob"
    )
    cron_at = Time.current.change(sec: 0, usec: 0)

    2.times { entry.enqueue(cron_at) }

    expect(GoodJob::Job.where(cron_key: "good_job_cron_dedup_probe").count).to eq(1)
  end
end
