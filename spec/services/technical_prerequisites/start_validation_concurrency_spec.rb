# frozen_string_literal: true

require "rails_helper"

RSpec.describe TechnicalPrerequisites::StartValidation do
  self.use_transactional_tests = false

  # @spec PARTIAL-CLOSEOUT-042
  it "admits one performance run when equivalent callers race" do
    project = create(:project)
    issue = create(:issue, project:)
    source_run = create(:agent_run, :completed, project:, issue:,
      base_commit_sha: "d" * 40, result_commit_sha: "c" * 40)
    requirement = create(:pre_commit_requirement, project:, account: project.account,
      check_type: "performance_measurement", command: "bin/measure", measurement_recipe: measurement_recipe)

    results = concurrently_start(source_run:, requirement:, actor: project.created_by)

    expect(results.map { |result| result.agent_run.id }.uniq).to contain_exactly(results.first.agent_run.id)
    expect(project.agent_runs.where(goal: AgentRun::TECHNICAL_PREREQUISITE_VALIDATION_GOAL).count).to eq(1)
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
    expect(jobs.count { |job| job[:job] == TechnicalPrerequisiteValidationJob }).to eq(1)
  ensure
    project&.account&.destroy!
  end

  private

  def concurrently_start(source_run:, requirement:, actor:)
    ready = Queue.new
    start = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          described_class.call(
            source_run: AgentRun.find(source_run.id),
            requirement: PreCommitRequirement.find(requirement.id),
            actor: User.find(actor.id),
            criterion: "Inbox allocations"
          )
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.map do |thread|
      raise "Concurrent performance admission timed out" unless thread.join(10)

      thread.value
    end
  ensure
    threads&.each { |thread| thread.kill.join if thread.alive? }
  end

  def measurement_recipe
    {
      "baseline_commit_sha" => "b" * 40,
      "workload" => {
        "identity" => "inbox-fixture",
        "provenance" => "reviewed fixture v1",
        "representative" => true
      },
      "metrics" => [ "wall_ms" ],
      "samples" => 3,
      "environment" => "isolated-linux",
      "budget_seconds" => 60,
      "artifact_contract" => [ "raw_samples", "comparison" ]
    }
  end
end
