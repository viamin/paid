# frozen_string_literal: true

require "rails_helper"

# @spec AUTO-PICK-QUEUE-022 AUTO-PICK-QUEUE-023
RSpec.describe CycleAnalyses::ApplyRepair do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user) }

  def remote_bodies_double(initial)
    bodies = initial.dup
    client = instance_double(GithubClient)
    allow(client).to receive(:issue) { |_repo, number| Struct.new(:body).new(bodies.fetch(number)) }
    allow(client).to receive(:update_issue) { |_repo, number, body:| bodies[number] = body; true }
    allow(client).to receive(:recent_issue_comments).and_return([])
    [ client, bodies ]
  end

  def stub_github_client(client)
    allow(GithubClient).to receive(:new).and_return(client)
  end

  def removal_candidate(edge_id)
    { "declaration_changes" => [ { "edge_id" => edge_id, "action" => "remove" } ],
      "evidence" => [ "clear" ], "missing_or_conflicting_intent" => [], "acyclic" => true }
  end

  def run_for(cycle)
    create(:agent_run, project: cycle.project, initiating_user: user, status: "running",
      goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => CycleAnalyses::Snapshot.call(cycle:) })
  end

  context "with a two-node cycle" do
    let(:first) { create(:issue, project:, github_number: 10, github_state: "open", body: "Depends on #11") }
    let(:second) { create(:issue, project:, github_number: 11, github_state: "open", body: "Depends on #10") }
    let!(:first_to_second_edge) do
      create_legacy_issue_dependency(issue: first, depends_on_issue: second,
        declaration_source: "issue_body", declaration_url: "https://github.com/acme/widgets/issues/10")
    end
    let!(:second_to_first_edge) do
      create_legacy_issue_dependency(issue: second, depends_on_issue: first,
        declaration_source: "issue_body", declaration_url: "https://github.com/acme/widgets/issues/11")
    end
    let(:cycle) { Issues::DependencyCycles.call(account:).sole }

    it "repairs the cycle and confirms the persisted graph is acyclic" do
      client, bodies = remote_bodies_double(10 => first.body, 11 => second.body)
      stub_github_client(client)
      snapshot = CycleAnalyses::Snapshot.call(cycle:)
      run = run_for(cycle)

      result = described_class.call(agent_run: run, candidate: removal_candidate(first_to_second_edge.id), snapshot:, actor: user)

      expect(result).to be_success
      expect(result.applied_changes).to eq([ first.id ])
      expect(client).to have_received(:update_issue).with(project.full_name, 10, body: "")
      expect(bodies[10]).to eq("")
      expect(first.reload.issue_dependencies).to be_empty
      expect(Issues::DependencyCycles.call(account:)).to be_empty
      expect(account.account_activity_events.where(action: "dependency_cycle.repaired")).to exist
    end

    it "re-fetches GitHub after the write before synchronizing the persisted graph" do
      client, = remote_bodies_double(10 => first.body, 11 => second.body)
      stub_github_client(client)
      snapshot = CycleAnalyses::Snapshot.call(cycle:)
      run = run_for(cycle)

      described_class.call(agent_run: run, candidate: removal_candidate(first_to_second_edge.id), snapshot:, actor: user)

      expect(client).to have_received(:issue).with(project.full_name, 10).twice
    end

    it "is idempotent when a retry re-applies after the edit already landed on GitHub" do
      client, bodies = remote_bodies_double(10 => "", 11 => second.body)
      stub_github_client(client)
      snapshot = CycleAnalyses::Snapshot.call(cycle:)
      run = run_for(cycle)

      result = described_class.call(agent_run: run, candidate: removal_candidate(first_to_second_edge.id), snapshot:, actor: user)

      expect(result).to be_success
      expect(client).not_to have_received(:update_issue)
      expect(bodies[10]).to eq("")
    end

    it "aborts without writing when the actor lacks run authority" do
      outsider = create(:user)
      client, = remote_bodies_double(10 => first.body, 11 => second.body)
      stub_github_client(client)
      snapshot = CycleAnalyses::Snapshot.call(cycle:)
      run = run_for(cycle)

      result = described_class.call(agent_run: run, candidate: removal_candidate(first_to_second_edge.id), snapshot:, actor: outsider)

      expect(result.status).to eq(:unauthorized)
      expect(client).not_to have_received(:update_issue)
    end

    it "aborts without writing when the occurrence changed since the snapshot" do
      client, = remote_bodies_double(10 => first.body, 11 => second.body)
      stub_github_client(client)
      snapshot = CycleAnalyses::Snapshot.call(cycle:)
      run = run_for(cycle)
      second_to_first_edge.destroy!

      result = described_class.call(agent_run: run, candidate: removal_candidate(first_to_second_edge.id), snapshot:, actor: user)

      expect(result.status).to eq(:stale)
      expect(client).not_to have_received(:update_issue)
    end

    it "aborts without writing when declaration provenance is no longer available" do
      client, = remote_bodies_double(10 => first.body, 11 => second.body)
      stub_github_client(client)
      snapshot = CycleAnalyses::Snapshot.call(cycle:)
      run = run_for(cycle)
      first_to_second_edge.update_columns(declaration_source: "issue_comment")

      result = described_class.call(agent_run: run, candidate: removal_candidate(first_to_second_edge.id), snapshot:, actor: user)

      expect(result.status).to eq(:provenance_unavailable)
      expect(client).not_to have_received(:update_issue)
    end

    it "aborts without writing when the declaration cannot be isolated to one line" do
      first.update!(body: "Depends on #11 and #12 both.")
      client, = remote_bodies_double(10 => first.body, 11 => second.body)
      stub_github_client(client)
      snapshot = CycleAnalyses::Snapshot.call(cycle:)
      run = run_for(cycle)

      result = described_class.call(agent_run: run, candidate: removal_candidate(first_to_second_edge.id), snapshot:, actor: user)

      expect(result.status).to eq(:declaration_not_isolated)
      expect(client).not_to have_received(:update_issue)
    end

    it "reports the write as failed and not successful when GitHub refuses the edit" do
      client, = remote_bodies_double(10 => first.body, 11 => second.body)
      allow(client).to receive(:update_issue).and_raise(GithubClient::Error, "rate limited")
      stub_github_client(client)
      snapshot = CycleAnalyses::Snapshot.call(cycle:)
      run = run_for(cycle)

      result = described_class.call(agent_run: run, candidate: removal_candidate(first_to_second_edge.id), snapshot:, actor: user)

      expect(result.status).to eq(:write_failed)
      expect(result.applied_changes).to eq([])
      expect(first.reload.issue_dependencies).not_to be_empty
    end

    it "reports a pending outcome when post-write confirmation is unavailable, without repeating the edit" do
      client, bodies = remote_bodies_double(10 => first.body, 11 => second.body)
      stub_github_client(client)
      snapshot = CycleAnalyses::Snapshot.call(cycle:)
      run = run_for(cycle)
      call_count = 0
      allow(Issues::DependencyCycles).to receive(:call).and_wrap_original do |original, **kwargs|
        call_count += 1
        raise Issues::DependencyCycles::CoverageUnavailable, "db unavailable" if call_count == 2

        original.call(**kwargs)
      end

      result = described_class.call(agent_run: run, candidate: removal_candidate(first_to_second_edge.id), snapshot:, actor: user)

      expect(result.status).to eq(:confirmation_unavailable)
      expect(bodies[10]).to eq("")
    end
  end

  context "with a redundant multi-edge group where one edge removal is not sufficient" do
    let(:a) { create(:issue, project:, github_number: 20, github_state: "open", body: "Depends on #21\nDepends on #22") }
    let(:b) { create(:issue, project:, github_number: 21, github_state: "open", body: "Depends on #20") }
    let(:c) { create(:issue, project:, github_number: 22, github_state: "open", body: "Depends on #20") }
    let!(:edge_a_b) { create_legacy_issue_dependency(issue: a, depends_on_issue: b, declaration_source: "issue_body", declaration_url: "https://x/1") }
    let(:cycle) { Issues::DependencyCycles.call(account:).sole }

    before do
      create_legacy_issue_dependency(issue: b, depends_on_issue: a, declaration_source: "issue_body", declaration_url: "https://x/2")
      create_legacy_issue_dependency(issue: a, depends_on_issue: c, declaration_source: "issue_body", declaration_url: "https://x/3")
      create_legacy_issue_dependency(issue: c, depends_on_issue: a, declaration_source: "issue_body", declaration_url: "https://x/4")
    end

    # a<->b and a<->c are each independently cyclic, so removing only the a->b
    # edge leaves the a<->c pair intact — a single edge removal is not
    # presumed sufficient for a multi-edge group (AUTO-PICK-QUEUE-021).
    it "does not mark the group resolved when the fresh graph is still cyclic after re-applying the change" do
      client, = remote_bodies_double(20 => a.body, 21 => b.body, 22 => c.body)
      stub_github_client(client)
      snapshot = CycleAnalyses::Snapshot.call(cycle:)
      run = run_for(cycle)

      result = described_class.call(agent_run: run, candidate: removal_candidate(edge_a_b.id), snapshot:, actor: user)

      expect(result.status).to eq(:verification_failed)
      expect(client).not_to have_received(:update_issue)
    end
  end

  context "with a multi-edge ring where one edge removal fully resolves it" do
    let(:a) { create(:issue, project:, github_number: 40, github_state: "open", body: "Depends on #41") }
    let(:b) { create(:issue, project:, github_number: 41, github_state: "open", body: "Depends on #42") }
    let(:c) { create(:issue, project:, github_number: 42, github_state: "open", body: "Depends on #40") }
    let!(:edge_a_b) { create_legacy_issue_dependency(issue: a, depends_on_issue: b, declaration_source: "issue_body", declaration_url: "https://x/1") }
    let(:cycle) { Issues::DependencyCycles.call(account:).sole }

    before do
      create_legacy_issue_dependency(issue: b, depends_on_issue: c, declaration_source: "issue_body", declaration_url: "https://x/2")
      create_legacy_issue_dependency(issue: c, depends_on_issue: a, declaration_source: "issue_body", declaration_url: "https://x/3")
    end

    it "repairs the group and confirms it acyclic" do
      client, bodies = remote_bodies_double(40 => a.body, 41 => b.body, 42 => c.body)
      stub_github_client(client)
      snapshot = CycleAnalyses::Snapshot.call(cycle:)
      run = run_for(cycle)

      result = described_class.call(agent_run: run, candidate: removal_candidate(edge_a_b.id), snapshot:, actor: user)

      expect(result).to be_success
      expect(bodies[40]).to eq("")
      expect(Issues::DependencyCycles.call(account:)).to be_empty
    end
  end

  context "when a GitHub write fails partway through a multi-issue plan" do
    let(:a) { create(:issue, project:, github_number: 50, github_state: "open", body: "Depends on #51") }
    let(:b) { create(:issue, project:, github_number: 51, github_state: "open", body: "Depends on #50\nDepends on #52") }
    let(:c) { create(:issue, project:, github_number: 52, github_state: "open", body: "Depends on #51") }
    let!(:edge_a_b) { create_legacy_issue_dependency(issue: a, depends_on_issue: b, declaration_source: "issue_body", declaration_url: "https://x/1") }
    let!(:edge_c_b) { create_legacy_issue_dependency(issue: c, depends_on_issue: b, declaration_source: "issue_body", declaration_url: "https://x/4") }
    let(:cycle) { Issues::DependencyCycles.call(account:).sole }

    before do
      create_legacy_issue_dependency(issue: b, depends_on_issue: a, declaration_source: "issue_body", declaration_url: "https://x/2")
      create_legacy_issue_dependency(issue: b, depends_on_issue: c, declaration_source: "issue_body", declaration_url: "https://x/3")
    end

    def multi_change_candidate(edge_ids)
      { "declaration_changes" => edge_ids.map { |id| { "edge_id" => id, "action" => "remove" } },
        "evidence" => [ "clear" ], "missing_or_conflicting_intent" => [], "acyclic" => true }
    end

    # Removing a->b and c->b leaves only b->a and b->c, a tree rooted at b
    # with no cycle — so this candidate's full change set genuinely resolves
    # the group, and the two removals are declared by two different issues
    # (a and c), exercising a true partial write failure across issues.
    it "records exactly which edits applied and does not report success" do
      client, bodies = remote_bodies_double(50 => a.body, 51 => b.body, 52 => c.body)
      call_count = 0
      allow(client).to receive(:update_issue) do |_repo, number, body:|
        call_count += 1
        raise GithubClient::Error, "rate limited" if call_count == 2

        bodies[number] = body
        true
      end
      stub_github_client(client)
      snapshot = CycleAnalyses::Snapshot.call(cycle:)
      run = run_for(cycle)

      result = described_class.call(
        agent_run: run, candidate: multi_change_candidate([ edge_a_b.id, edge_c_b.id ]), snapshot:, actor: user
      )

      expect(result.status).to eq(:write_failed)
      expect(result.applied_changes.size).to eq(1)
      expect(Issues::DependencyCycles.call(account:)).not_to be_empty
    end
  end

  # @spec AUTO-PICK-QUEUE-021 AUTO-PICK-QUEUE-022
  # Required regression for the issue's own persisted cycle: the local
  # IssueDependency rows predate provenance tracking (declaration_source and
  # declaration_url are both nil), yet the validation issue's current GitHub
  # body contains the exact, unique "Depends on #<closeout>" declaration.
  # Missing local provenance alone must not block the repair.
  context "when local provenance is missing but the live declaration is unique (RDR-075 regression)" do
    let(:closeout_issue) { create(:issue, project:, github_number: 4334, github_state: "open", body: "Depends on #4635") }
    let(:accepted_intent_issue) { create(:issue, project:, github_number: 4635, github_state: "open", body: "Depends on #4604") }
    let(:validation_issue) do
      create(:issue, project:, github_number: 4604, github_state: "open",
        body: "Live validation evidence must precede acceptance and implementation.\n\nDepends on #4334")
    end
    let!(:validation_depends_on_closeout_edge) do
      create_legacy_issue_dependency(issue: validation_issue, depends_on_issue: closeout_issue,
        declaration_source: nil, declaration_url: nil)
    end
    let(:cycle) { Issues::DependencyCycles.call(account:).sole }

    before do
      create_legacy_issue_dependency(issue: accepted_intent_issue, depends_on_issue: validation_issue,
        declaration_source: nil, declaration_url: nil)
      create_legacy_issue_dependency(issue: closeout_issue, depends_on_issue: accepted_intent_issue,
        declaration_source: nil, declaration_url: nil)
    end

    it "identifies and removes only the validation-depends-on-closeout declaration, leaving the rest of the chain intact" do
      client, bodies = remote_bodies_double(
        4334 => closeout_issue.body, 4635 => accepted_intent_issue.body, 4604 => validation_issue.body
      )
      stub_github_client(client)
      snapshot = CycleAnalyses::Snapshot.call(cycle:)
      run = run_for(cycle)

      result = described_class.call(
        agent_run: run, candidate: removal_candidate(validation_depends_on_closeout_edge.id), snapshot:, actor: user
      )

      expect(result).to be_success
      expect(result.applied_changes).to eq([ validation_issue.id ])
      expect(bodies[4604]).to eq("Live validation evidence must precede acceptance and implementation.\n\n")
      expect(accepted_intent_issue.reload.issue_dependencies.map(&:depends_on_issue_id)).to eq([ validation_issue.id ])
      expect(closeout_issue.reload.issue_dependencies.map(&:depends_on_issue_id)).to eq([ accepted_intent_issue.id ])
      expect(Issues::DependencyCycles.call(account:)).to be_empty
    end

    it "leaves GitHub untouched when the declaration can no longer be uniquely matched at write time" do
      validation_issue.update!(body: "Depends on #4334\nDepends on #4334 (duplicate note)")
      client, = remote_bodies_double(
        4334 => closeout_issue.body, 4635 => accepted_intent_issue.body, 4604 => validation_issue.body
      )
      stub_github_client(client)
      snapshot = CycleAnalyses::Snapshot.call(cycle:)
      run = run_for(cycle)

      result = described_class.call(
        agent_run: run, candidate: removal_candidate(validation_depends_on_closeout_edge.id), snapshot:, actor: user
      )

      expect(result.status).to eq(:declaration_not_isolated)
      expect(client).not_to have_received(:update_issue)
      expect(validation_issue.reload.issue_dependencies.map(&:depends_on_issue_id)).to eq([ closeout_issue.id ])
    end

    it "leaves GitHub untouched when the live body no longer declares the dependency at all" do
      validation_issue.update!(body: "Live validation evidence must precede acceptance and implementation.")
      client, = remote_bodies_double(
        4334 => closeout_issue.body, 4635 => accepted_intent_issue.body, 4604 => validation_issue.body
      )
      stub_github_client(client)
      snapshot = CycleAnalyses::Snapshot.call(cycle:)
      run = run_for(cycle)

      result = described_class.call(
        agent_run: run, candidate: removal_candidate(validation_depends_on_closeout_edge.id), snapshot:, actor: user
      )

      expect(result.status).to eq(:declaration_not_isolated)
      expect(client).not_to have_received(:update_issue)
      expect(validation_issue.reload.issue_dependencies.map(&:depends_on_issue_id)).to eq([ closeout_issue.id ])
    end
  end

  context "with cross-project authorization" do
    let(:other_project) { create(:project, account:, created_by: user) }
    let(:first) { create(:issue, project:, github_number: 30, github_state: "open", body: "Depends on acme-other#31") }
    let(:second) { create(:issue, project: other_project, github_number: 31, github_state: "open", body: "Depends on #30") }
    let!(:first_to_second_edge) do
      create_legacy_issue_dependency(issue: first, depends_on_issue: second,
        declaration_source: "issue_body", declaration_url: "https://x/cross")
    end
    let(:cycle) { Issues::DependencyCycles.call(account:).sole }

    before do
      create_legacy_issue_dependency(issue: second, depends_on_issue: first,
        declaration_source: "issue_body", declaration_url: "https://x/back")
    end

    it "requires authority on every represented project, not only the first" do
      limited_actor = create(:user, :viewer, account:)
      limited_actor.add_role(:project_member, project)
      client, = remote_bodies_double(30 => first.body, 31 => second.body)
      stub_github_client(client)
      snapshot = CycleAnalyses::Snapshot.call(cycle:)
      run = run_for(cycle)

      result = described_class.call(agent_run: run, candidate: removal_candidate(first_to_second_edge.id), snapshot:, actor: limited_actor)

      expect(result.status).to eq(:unauthorized)
      expect(client).not_to have_received(:update_issue)
    end
  end
end
