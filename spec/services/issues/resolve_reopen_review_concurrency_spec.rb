# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ResolveReopenReview do
  self.use_transactional_tests = false

  # @spec ISSUE-REOPEN-REVIEW-005
  it "records only one decision when operators resolve the same review concurrently" do
    project = create(:project)
    issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON,
      github_updated_at: Time.current.change(usec: 0))
    threads = concurrent_resolutions(issue, project.created_by)

    results = threads.map do |thread|
      raise "Concurrent reopen resolution timed out" unless thread.join(10)

      thread.value
    end

    expect(results.count(&:success?)).to eq(1)
    expect(AccountActivityEvent.where(subject: issue, action: "issue.updated").count).to eq(1)
  ensure
    threads&.each { |thread| thread.kill.join if thread.alive? }
    project&.account&.destroy!
  end

  def concurrent_resolutions(issue, actor)
    ready = Queue.new
    start = Queue.new
    threads = 2.times.map { resolution_thread(issue, actor, ready, start) }
    2.times { ready.pop }
    2.times { start << true }
    threads
  end

  def resolution_thread(issue, actor, ready, start)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ready << true
        start.pop
        described_class.call(issue: Issue.find(issue.id), actor: User.find(actor.id),
          reason: "Closure evidence is incomplete.", revision: issue.github_updated_at.iso8601)
      end
    end
  end
end
