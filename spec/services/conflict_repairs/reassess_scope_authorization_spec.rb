# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe ConflictRepairs::ReassessScope do # @spec AUTO-MERGE-011
  self.use_transactional_tests = false

  let(:project) { create(:project) }
  let(:requester) { create(:user, :member, account: project.account) }
  let(:issue) { create(:issue, :pull_request, project:, github_number: 42) }
  let(:run) do
    create(:agent_run, :automatic, :failed, project:, issue:, goal: "create_pr", focus: "merge_conflict",
      source_pull_request_number: 42, result_commit_sha: "result-sha",
      external_metadata: { "pre_run_head_sha" => "pre-sha" })
  end
  let(:provider_response) do
    { status: 200, body: { head: { sha: "provider-moved" }, base: { sha: "base-sha" } }.to_json,
      headers: { "Content-Type" => "application/json" } }
  end
  let(:provider_url) { "https://api.github.com/repos/#{project.full_name}/pulls/42" }
  let(:provider_request) { stub_request(:get, provider_url) }

  before do
    requester
    run
    provider_request.to_return(provider_response)
  end

  after do
    ConflictRepairScopeEvidence.where(project_id: project.id).delete_all
    project.account.destroy!
  end

  it "serializes account-role revocation after an authorized publication" do
    with_publication_paused do
      expect {
        with_short_lock_timeout { requester.add_role(:viewer, project.account) }
      }.to raise_error(ActiveRecord::LockWaitTimeout)
    end

    expect(ConflictRepairScopeEvidence.where(agent_run: run).sole.status).to eq("unavailable")
    requester.add_role(:viewer, project.account)
    expect(described_class.call(agent_run: run, requested_by: requester).status).to eq(:refused)
    expect(ConflictRepairScopeEvidence.where(agent_run: run).count).to eq(1)
  end

  it "serializes project-role removal after an authorized publication" do
    requester.add_role(:viewer, project.account)
    requester.add_role(:project_member, project)

    with_publication_paused do
      expect {
        with_short_lock_timeout { requester.remove_role(:project_member, project) }
      }.to raise_error(ActiveRecord::LockWaitTimeout)
    end

    requester.remove_role(:project_member, project)
    expect(described_class.call(agent_run: run, requested_by: requester).status).to eq(:refused)
    expect(ConflictRepairScopeEvidence.where(agent_run: run).count).to eq(1)
  end

  it "refuses publication when a concurrent revocation commits during provider work" do
    main_pid = ActiveRecord::Base.connection.raw_connection.backend_pid
    stub_request(:get, provider_url).to_return do
      expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
      revoke_pid = in_another_session { requester.add_role(:viewer, project.account) }
      expect(revoke_pid).not_to eq(main_pid)
      expect(AgentRunPolicy.new(User.find(requester.id), run).retry?).to be(false)
      provider_response
    end

    result = described_class.call(agent_run: run, requested_by: requester)

    expect(result).to have_attributes(status: :refused, reason: "requesting_actor_not_authorized", evidence: nil)
    expect(ConflictRepairScopeEvidence.where(agent_run: run)).not_to exist
    expect(run.reload.status).to eq("failed")
  end

  def with_short_lock_timeout(&block)
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '100ms'")
      block.call
    end
  end

  def in_another_session(&block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        TenantContext.with(project.account) do
          with_short_lock_timeout { block.call }
          connection.raw_connection.backend_pid
        end
      end
    end.value
  end

  def with_publication_paused
    ready = Queue.new
    release = Queue.new
    producer_id = run.id
    requester_id = requester.id
    account = project.account
    callback = ->(evidence) do
      if evidence.agent_run_id == producer_id
        ready << ActiveRecord::Base.connection.raw_connection.backend_pid
        release.pop
      end
    end
    ConflictRepairScopeEvidence.set_callback(:create, :before, callback)
    publisher = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TenantContext.with(account) do
          described_class.call(agent_run: AgentRun.find(producer_id), requested_by: User.find(requester_id))
        end
      end
    end
    publisher_pid = Timeout.timeout(10) { ready.pop }
    expect(publisher_pid).not_to eq(ActiveRecord::Base.connection.raw_connection.backend_pid)
    yield
  ensure
    release << true
    ConflictRepairScopeEvidence.skip_callback(:create, :before, callback) if callback
    if publisher
      unless publisher.join(10)
        publisher.kill.join
        raise "Publication did not finish"
      end
      expect(publisher.value).to be_accepted
    end
  end
end
