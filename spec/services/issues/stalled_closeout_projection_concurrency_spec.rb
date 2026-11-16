# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe Issues::StalledCloseoutProjection do # @spec PARTIAL-CLOSEOUT-042
  self.use_transactional_tests = false

  it "serializes snapshot computation before replacing a newer projection" do
    account = create(:account)
    project = create(:project, account:, auto_pick_enabled: true)
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project:)
    issue = create_stalled_issue(project)
    race = start_first_projection(project)
    race[:project_writer] = update_project(project)

    expect(Timeout.timeout(5) { race[:project_writer].join }).to eq(race[:project_writer])

    issue.update!(github_state: "closed")
    race[:second] = start_second_projection(project, race[:second_entered])

    expect { race[:second_entered].pop(true) }.to raise_error(ThreadError)
    race[:release_first] << true
    race.values_at(:first, :second).each { |thread| expect(thread.join(10)).to eq(thread) }

    expect(race[:second_entered].pop).to be(true)
    expect(project.reload.partial_closeout_projection.entries).to be_empty
  ensure
    race&.dig(:release_first)&.push(true) if race&.dig(:first)&.alive?
    race&.values_at(:first, :second)&.compact&.each { |thread| thread.kill.join if thread.alive? }
    account&.destroy!
  end

  private

  def projection_thread(project, snapshot)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TenantContext.with(project.account) do
          described_class.call(project: Project.find(project.id), stalled_closeouts: snapshot)
        end
      end
    end
  end

  def update_project(project)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TenantContext.with(project.account) { Project.find(project.id).touch }
      end
    end
  end

  def start_first_projection(project)
    first_entered = Queue.new
    release_first = Queue.new
    first = projection_thread(project, evaluator do |projects|
      pairs = Issues::StalledCloseouts.call(projects)
      first_entered << true
      release_first.pop
      pairs
    end)
    Timeout.timeout(5) { first_entered.pop }
    { first:, release_first:, second_entered: Queue.new }
  end

  def start_second_projection(project, second_entered)
    projection_thread(project, evaluator do |projects|
      second_entered << true
      Issues::StalledCloseouts.call(projects)
    end)
  end

  def evaluator(&block)
    Object.new.tap { |object| object.define_singleton_method(:call, &block) }
  end

  def create_stalled_issue(project)
    issue = create(:issue, project:, github_state: "open", paid_state: "in_progress")
    create(:issue, :pull_request, project:, parent_issue_id: issue.id, github_state: "closed",
      pr_review_phase: "merged", github_number: issue.github_number + 100)
    issue
  end
end
