# frozen_string_literal: true

require "rails_helper"
require "timeout"

# @spec AUTO-MERGE-011
RSpec.describe ConflictRepairs::ReassessScope do
  self.use_transactional_tests = false

  let(:project) { create(:project) }
  let(:requester) { create(:user, :member, account: project.account) }
  let(:issue) { create(:issue, :pull_request, project:, github_number: 42) }
  let(:run) do
    create(:agent_run, :automatic, :failed, project:, issue:, goal: "create_pr", focus: "merge_conflict",
      source_pull_request_number: 42, result_commit_sha: "result-sha", external_metadata: { "pre_run_head_sha" => "pre-sha" })
  end

  before { run }

  after do
    TenantContext.with_system_access do
      ConflictRepairScopeEvidence.where(agent_run: run).delete_all
      project.account.destroy!
    end
  end

  it "serializes publication with concurrent requester revocation" do
    publishing = Queue.new
    release_publication = Queue.new
    delay_evidence_publication(publishing, release_publication)

    reassessment = reassess_in_thread
    publishing.pop
    revocation_started = Queue.new
    revocation = revoke_in_thread(revocation_started)
    revocation_started.pop
    wait_for_thread_to_block(revocation)

    release_publication << true
    expect(reassessment.value).to have_attributes(status: "approved")
    expect(revocation.value).to be_a(AccountMembership)
    expect(ConflictRepairScopeEvidence.where(agent_run: run)).to have_attributes(count: 1)
    expect(requester.reload.has_role?(:viewer, project.account)).to be(true)
  ensure
    release_publication << true if release_publication
    [ reassessment, revocation ].compact.each { |thread| thread.kill.join if thread.alive? }
  end

  private

  def delay_evidence_publication(publishing, release_publication)
    allow(ConflictRepairScopeEvidence).to receive(:create_or_find_by!).and_wrap_original do |original, *arguments, &block|
      if Thread.current[:reassessing_conflict_scope]
        publishing << true
        release_publication.pop
      end
      original.call(*arguments, &block)
    end
  end

  def reassess_in_thread
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TenantContext.with(project.account) do
          Thread.current[:reassessing_conflict_scope] = true
          described_class.new(agent_run: AgentRun.find(run.id), requested_by: User.find(requester.id))
            .send(:record, "approved", "bounded repair", [], [], "result-sha", "base-sha")
        ensure
          Thread.current[:reassessing_conflict_scope] = nil
        end
      end
    end
  end

  def revoke_in_thread(revocation_started)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TenantContext.with_system_access do
          account = Account.find(project.account_id)
          TenantContext.with(account) do
            revocation_started << true
            User.find(requester.id).add_role(:viewer, account)
          end
        end
      end
    end
  end

  def wait_for_thread_to_block(thread)
    Timeout.timeout(5) do
      loop do
        return if thread.status == "sleep"

        Thread.pass
      end
    end
  end
end
