# frozen_string_literal: true

require "rails_helper"

# @spec CONFIDENCE-DELIVERY-008
RSpec.describe FeatureIntents::CompleteForwardWork do
  self.use_transactional_tests = false

  let(:project) { create(:project) }
  let(:feature_intent) { create(:feature_intent, project: project) }
  let(:completion_issue) { create(:issue, project: project, github_number: 700, body: "Completion") }
  let(:implementation_issue) { create(:issue, project: project, github_number: 701, body: "Implementation") }
  let(:client) { instance_double(GithubClient) }
  let(:remote_bodies) { { 700 => "Completion", 701 => "Implementation" } }
  let(:remote_issue) { Data.define(:body, :state) }

  before do
    [ completion_issue, implementation_issue ].each { |issue| FeatureIntentIssue.create!(feature_intent: feature_intent, issue: issue) }
    allow(client).to receive(:issue) { |_repo, number| remote_issue.new(body: remote_bodies.fetch(number), state: "open") }
    allow(client).to receive(:update_issue) { |_repo, number, body: nil, **_options| remote_bodies[number] = body if body }
  end

  after do
    feature_intent.destroy!
    project.destroy!
  end

  it "keeps concurrent first writers on one completion and routes the finding once" do
    concurrent_findings

    completion = FeatureIntentCompletion.where(feature_intent: feature_intent).sole
    expect(completion.forward_work_items.where(fingerprint: "a" * 64).count).to eq(1)
  end

  private

  def concurrent_findings
    ready = Queue.new
    start = Queue.new
    threads = 2.times.map { concurrent_finding_thread(ready, start) }
    2.times { ready.pop }
    2.times { start << true }
    threads.each { |thread| raise "Concurrent finding timed out" unless thread.join(10) }
  ensure
    threads&.each { |thread| thread.kill.join if thread.alive? }
  end

  def concurrent_finding_thread(ready, start)
    Thread.new do
      ready << true
      start.pop
      ActiveRecord::Base.connection_pool.with_connection { record_finding }
    end
  end

  def record_finding
    TenantContext.with_system_access do
      described_class.record_finding(
        feature_intent: FeatureIntent.find(feature_intent.id), completion_issue: Issue.find(completion_issue.id),
        affected_issue: Issue.find(implementation_issue.id), client:, fingerprint: "a" * 64,
        finding: { summary: "Concurrent finding." }
      )
    end
  end
end
