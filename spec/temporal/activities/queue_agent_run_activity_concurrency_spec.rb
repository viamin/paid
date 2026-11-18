# frozen_string_literal: true

require "rails_helper"
require "timeout"

# @spec TEMPORAL-ORCHESTRATION-012 AUTOMATION-PHASES-014
RSpec.describe Activities::QueueAgentRunActivity do
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  let(:project) { create(:project) }

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = original_adapter
  end

  after do
    project.account.destroy!
  end

  it "recovers the winning insert and merges draft tracking after rolling back the loser" do
    winner, loser = race_admissions

    expect(winner).to include(queued: true)
    expect(loser).to include(agent_run_id: winner[:agent_run_id], queued: false, duplicate: true)
    expect(project.agent_runs.count).to eq(1)
    expect(project.agent_runs.sole).to have_attributes(
      count_toward_draft_review_round: true, expected_draft_review_count: 5
    )
    expect(enqueued_jobs.count { |job| job[:job] == ProcessRunQueueJob }).to eq(1)
  end

  it "refuses an automatic insertion that waited for phase rollout rollback" do
    FeatureFlags.enable!(:automation_phases, project:)
    project.update!(automation_phase_settings: { "phases" => { "coding" => false } })
    issue = create(:issue, project:)

    result = race_rollback_and_admission(issue)

    expect(result).to include(queued: false, skipped: true, reason: "phase_rollout_changed")
    expect(project.agent_runs).to be_empty
    expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(false)
  end

  private

  def race_rollback_and_admission(issue)
    rollback_locked = Queue.new
    release_rollback = Queue.new
    admission_backend = Queue.new
    observer = rollback_barrier(rollback_locked, release_rollback)

    ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
      rollback = rollback_thread
      Timeout.timeout(10) { rollback_locked.pop }
      admission = queue_thread(
        { project_id: project.id, issue_id: issue.id, goal: "create_pr" },
        backend_pid: admission_backend
      )
      wait_for_project_lock(Timeout.timeout(10) { admission_backend.pop })
      release_rollback << true

      thread_value(rollback, "Rollback")
      thread_value(admission, "Admission")
    ensure
      release_rollback << true
      [ rollback, admission ].compact.each { |thread| thread.kill.join if thread.alive? }
    end
  end

  def race_admissions
    # Materialize shared setup before the two independent connections start.
    project.created_by.settings
    project.account.tenant_setting!
    input = { project_id: project.id, source_pull_request_number: 42, goal: "create_pr" }
    first_locked = Queue.new
    release_first = Queue.new
    second_backend = Queue.new
    threads = []
    observer = admission_barrier(first_locked, release_first)

    ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
      threads << queue_thread(input, lock_gate: release_first)
      Timeout.timeout(10) { first_locked.pop }
      threads << queue_thread(input.merge(count_toward_draft_review_round: true,
        expected_draft_review_count: 5), backend_pid: second_backend)

      wait_for_project_lock(Timeout.timeout(10) { second_backend.pop })
      release_first << true
      raise "Winning admission timed out" unless threads[0].join(10)
      threads[0].value

      raise "Duplicate admission timed out" unless threads[1].join(10)
      threads.map(&:value)
    end
  ensure
    release_first << true
    threads&.each { |thread| thread.kill.join if thread.alive? }
  end

  def admission_barrier(locked, release)
    lambda do |event|
      gate = Thread.current[:queue_admission_lock_gate]
      next unless gate && project_lock?(event.payload[:sql])

      Thread.current[:queue_admission_lock_gate] = nil
      locked << true
      release.pop
    end
  end

  def queue_thread(input, lock_gate: nil, backend_pid: nil)
    Thread.new do
      Thread.current[:queue_admission_lock_gate] = lock_gate
      ActiveRecord::Base.connection_pool.with_connection do
        backend_pid << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()") if backend_pid
        described_class.new.execute(input)
      end
    end
  end

  def rollback_thread
    Thread.new do
      Thread.current[:rollback_barrier] = true
      ActiveRecord::Base.connection_pool.with_connection do
        FeatureFlags.disable!(:automation_phases, project:)
      end
    end
  end

  def rollback_barrier(rollback_locked, release_rollback)
    lambda do |event|
      sql = event.payload[:sql]
      next unless Thread.current[:rollback_barrier] && rollback_lock?(sql)

      Thread.current[:rollback_barrier] = nil
      rollback_locked << true
      release_rollback.pop
    end
  end

  def project_lock?(sql)
    sql.include?(%q("projects")) && sql.include?("FOR UPDATE")
  end

    def rollback_lock?(sql)
      sql.include?("pg_advisory_xact_lock")
    end

  def wait_for_project_lock(backend_pid)
    Timeout.timeout(10) do
      loop do
        waiting = ActiveRecord::Base.connection.select_value(<<~SQL)
          SELECT EXISTS (
            SELECT 1 FROM pg_stat_activity
            WHERE pid = #{Integer(backend_pid)} AND wait_event_type = 'Lock'
          )
        SQL
        break if ActiveModel::Type::Boolean.new.cast(waiting)

        Thread.pass
      end
    end
  end

  def thread_value(thread, label)
    raise "#{label} timed out" unless thread.join(10)

    thread.value
  end
end
