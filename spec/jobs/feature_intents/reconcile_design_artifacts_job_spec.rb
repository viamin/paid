# frozen_string_literal: true

require "rails_helper"

# @spec DESIGN-RECONCILIATION-001
RSpec.describe FeatureIntents::ReconcileDesignArtifactsJob do
  def discovery(artifacts, complete: true)
    FeatureIntents::DiscoverRdrArtifacts::Discovery.new(
      artifacts:, revision: "a" * 40, coverage_complete: complete,
      directory_status: complete ? :matching_files : :unavailable
    )
  end

  def rdr_artifact(number, revision, body)
    FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: "docs/rdrs/RDR-#{number}.md", revision:, body:
    )
  end

  def issue_queries
    queries = []
    ActiveSupport::Notifications.subscribed(->(event) { queries << event.payload[:sql] }, "sql.active_record") { yield }
    queries.grep(/SELECT .* FROM "issues"/)
  end

  let(:project) { create(:project, owner: "acme", repo: "widget") }
  let(:feature_intent) { create(:feature_intent, project:) }
  let(:design_pr) { create(:feature_intent_design_pr, feature_intent:, pull_request_number: 100, draft: false) }

  before do
    response = instance_double(AgentHarness::Response, success?: false, output: nil)
    allow(AgentHarness).to receive(:send_message).and_return(response)
  end

  # @spec DESIGN-RECONCILIATION-002
  describe "coalescing", :good_job do
    around do |example|
      original_adapter = described_class.queue_adapter
      described_class.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)
      example.run
    ensure
      described_class.queue_adapter = original_adapter
    end

    it "persists one delayed job per project without pushing its deadline back" do
      freeze_time do
        first = described_class.enqueue_for(project.id)
        deadline = GoodJob::Job.find(first.provider_job_id).scheduled_at
        travel 10.seconds
        described_class.enqueue_for(project.id)
        described_class.enqueue_for(create(:project).id)

        jobs = GoodJob::Job.where(job_class: described_class.name, finished_at: nil)
        expect(jobs.count).to eq(2)
        expect(GoodJob::Job.find(first.provider_job_id).scheduled_at).to eq(deadline)
        expect(deadline).to eq(20.seconds.from_now)
      end
    end

    it "retains one follow-up when syncs arrive while a project reconciliation is running" do
      client = instance_double(GithubClient)
      allow(GithubClient).to receive(:new).and_return(client)
      allow(client).to receive(:ref).and_raise(GithubClient::Error, "unavailable")
      parent = described_class.perform_later(project.id)
      subscriber = lambda do |event|
        next unless event.payload[:job].job_id == parent.job_id

        2.times { described_class.enqueue_for(project.id) }
      end

      ActiveSupport::Notifications.subscribed(subscriber, "perform_start.active_job") do
        GoodJob::Job.find(parent.provider_job_id).perform(lock_id: SecureRandom.uuid)
      end

      pending = GoodJob::Job.where(job_class: described_class.name, finished_at: nil).sole
      expect(pending.serialized_params.fetch("arguments")).to eq([ project.id ])
      expect(described_class.good_job_concurrency_config).to include(enqueue_limit: 1, perform_limit: 1)
      expect(described_class.good_job_concurrency_config).not_to have_key(:total_limit)
    end

    it "waits for synchronized evidence to commit before coalescing or enqueueing" do
      project_id = project.id
      ActiveRecord::Base.transaction do
        described_class.enqueue_for(project_id)
        expect(GoodJob::Job.where(job_class: described_class.name)).to be_empty
      end

      expect(GoodJob::Job.where(job_class: described_class.name).sole.serialized_params.fetch("arguments"))
        .to eq([ project_id ])
    end

    it "does not enqueue a reconciliation for a rolled-back synchronization" do
      project_id = project.id
      ActiveRecord::Base.transaction do
        described_class.enqueue_for(project_id)
        raise ActiveRecord::Rollback
      end

      expect(GoodJob::Job.where(job_class: described_class.name)).to be_empty
    end
  end

  # @spec DESIGN-RECONCILIATION-002
  describe "memory measurements" do
    before { allow(Rails.logger).to receive(:info) }

    it "records process memory, allocations and elapsed time for a complete execution" do
      described_class.perform_now(project.id, 999)

      expect(Rails.logger).to have_received(:info).with(hash_including(
        message: "feature_intents.reconciliation_started", project_id: project.id,
        rss_kb: be_a(Integer).or(be_nil)
      ))
      expect(Rails.logger).to have_received(:info).with(hash_including(
        message: "feature_intents.reconciliation_finished", project_id: project.id,
        status: "completed", allocated_objects: be >= 0, duration_ms: be >= 0,
        artifacts_reconciled: be >= 0, issues_covered: be >= 0,
        rss_before_kb: be_a(Integer).or(be_nil), rss_after_kb: be_a(Integer).or(be_nil),
        process_peak_rss_kb: be_a(Integer).or(be_nil)
      ))
    end

    it "records failure measurements without swallowing the failure" do
      client = instance_double(GithubClient)
      allow(GithubClient).to receive(:new).and_return(client)
      allow(client).to receive(:ref).and_raise(TypeError, "unexpected response")

      expect { described_class.perform_now(project.id) }.to raise_error(TypeError, "unexpected response")

      expect(Rails.logger).to have_received(:info).with(hash_including(
        message: "feature_intents.reconciliation_finished", status: "failed", project_id: project.id
      ))
    end

    it "still reconciles when the diagnostic procfs read exhausts file descriptors" do
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with("/proc/self/status").and_raise(Errno::EMFILE)

      expect { described_class.perform_now(project.id, 999) }.not_to raise_error
      expect(Rails.logger).to have_received(:info).with(hash_including(
        message: "feature_intents.reconciliation_finished", status: "completed", rss_after_kb: nil
      ))
    end
  end

  it "persists an actionable finding from a synced design pull request" do
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number, body: "No issue tree yet")

    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.sole).to have_attributes(
      artifact_path: "pull/100", revision: design_pr.head_sha, state: "missing_tree", status: "open"
    )
  end

  # @spec OPERATOR-INBOX-020
  it "does not treat a synced draft design pull request without links as missing" do
    design_pr.update!(draft: true)
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number, body: "No issue tree yet")

    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.sole).to have_attributes(
      artifact_path: "pull/100", revision: design_pr.head_sha, state: "deferred", status: "deferred"
    )
  end

  it "treats an unknown draft state as unverifiable until synchronization" do
    design_pr.update!(draft: nil)
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number, body: "No issue tree yet")

    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.sole).to have_attributes(
      artifact_path: "pull/100", revision: design_pr.head_sha, state: "unverifiable", status: "open"
    )
  end

  it "treats a design pull request missing from the local issue mirror as unverifiable" do
    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.sole).to have_attributes(
      artifact_path: "pull/100", revision: design_pr.head_sha, state: "unverifiable", status: "open"
    )
  end

  # @spec OPERATOR-INBOX-020
  it "does not treat draft, deferred, superseded, or historical RDRs without links as missing" do
    [ "Draft", "Deferred", "Superseded", "Historical" ].each do |status|
      artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
        path: "docs/rdrs/RDR-#{status.downcase}.md",
        revision: status.downcase,
        body: "- **Status**: #{status}"
      )
      allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return(discovery([ artifact ]))

      described_class.perform_now(project.id)

      expect(DesignArtifactFinding.find_by!(artifact_path: artifact.path)).to have_attributes(
        state: "deferred", status: "deferred"
      )
    end
  end

  it "uses explicit linked issue references to clear the finding" do
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number, body: "**Implements:** #101")
    create(:issue, project:, github_number: 101)

    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.count).to eq(0)
  end

  it "loads issue coverage without duplicating project audit history per issue" do
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number, body: "Implements #101")
    create(:issue, project:, github_number: 101)
    queries = []
    subscriber = ->(event) { queries << event.payload[:sql] }

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      described_class.perform_now(project.id, design_pr.pull_request_number)
    end

    issue_queries = queries.grep(/SELECT .* FROM "issues"/)
    expect(issue_queries).not_to be_empty
    expect(issue_queries.grep(/"projects"\."log_data"/)).to be_empty
    expect(DesignArtifactFinding.count).to eq(0)
  end

  # @spec DESIGN-RECONCILIATION-001
  it "reuses one bounded issue snapshot across multiple RDR artifacts" do
    shared_project = create(:project, account: project.account, owner: "shared", repo: "platform")
    artifacts = [ rdr_artifact(101, "a" * 40, "Implements #101"),
                  rdr_artifact(102, "b" * 40, "Implements shared/platform#102"),
                  rdr_artifact(103, "c" * 40, "Implements #103") ]
    [ [ project, 101 ], [ shared_project, 102 ], [ project, 103 ] ].each do |covered_project, number|
      create(:issue, project: covered_project, github_number: number)
    end
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return(discovery(artifacts))

    covered = issue_queries { described_class.perform_now(project.id) }

    expect(covered.count).to eq(2)
    expect(DesignArtifactFinding.count).to eq(0)
    expect(DesignArtifactAssociation.pluck(:issue_identity)).to contain_exactly(
      "acme/widget#101", "shared/platform#102", "acme/widget#103"
    )
  end

  it "uses a stored Paid feature-intent link without requiring a document repair" do
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number, body: "No issue tree yet")
    linked_issue = create(:issue, project:, github_number: 101)
    create(:feature_intent_issue, feature_intent:, issue: linked_issue)

    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.count).to eq(0)
    expect(DesignArtifactAssociation.sole.provenance).to eq("Paid feature intent linkage")
  end

  it "assesses synchronized open issue candidates before creating a missing-tree finding" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    response = instance_double(AgentHarness::Response, success?: true,
      output: '{"issue_identity":"acme/widget#101","explanation":"It implements this design."}')
    allow(AgentHarness).to receive(:send_message).and_return(response)
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number, body: "No issue tree yet")
    create(:issue, project:, github_number: 101, title: "Implement design", body: "Implementation work")

    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.count).to eq(0)
    expect(DesignArtifactAssociation.sole).to have_attributes(issue_identity: "acme/widget#101")
  end

  it "uses issue links listed under an RDR relationship heading" do
    artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: "docs/rdrs/RDR-020-service-container-architecture.md",
      revision: "a" * 40,
      body: "### Related Issues\n\n- #216\n"
    )
    create(:issue, project:, github_number: 216)
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return(discovery([ artifact ]))

    described_class.perform_now(project.id)

    expect(DesignArtifactFinding.count).to eq(0)
  end

  it "preserves external URL and ownership-table identities without inventing local references" do
    forager = create(:project, account: project.account, owner: "viamin", repo: "Forager-iOS")
    [ 4255, 4256, 4258, 4325 ].each { |number| create(:issue, project: forager, github_number: number) }
    artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: "docs/rdrs/RDR-003-project-readiness-bootstrap.md", revision: "73558a022fdb2a5db9332bbeac8b22f5d661ad04",
      body: <<~MARKDOWN
        Status: Closed (superseded by Paid RDR-074 and its readiness issue tree)

        ## Issue ownership

        | Owner | Work |
        | --- | --- |
        | viamin/Forager-iOS | [#4255](https://github.com/viamin/Forager-iOS/issues/4255), #4256, viamin/Forager-iOS#4258, https://github.com/viamin/Forager-iOS/issues/4325 |
      MARKDOWN
    )
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return(discovery([ artifact ]))

    described_class.perform_now(project.id)

    expect(DesignArtifactFinding.find_by(artifact_path: artifact.path)).to have_attributes(state: "deferred", status: "deferred")
    expect(DesignArtifactAssociation.where(artifact_path: artifact.path).pluck(:issue_identity)).to contain_exactly(
      "viamin/Forager-iOS#4255", "viamin/Forager-iOS#4256", "viamin/Forager-iOS#4258", "viamin/Forager-iOS#4325"
    )
  end

  # @spec DESIGN-RECONCILIATION-001
  it "recognizes plural ownership headers without treating external bare references as local issue links" do
    forager = create(:project, account: project.account, owner: "viamin", repo: "Forager-iOS")
    [ 4255, 4256 ].each { |number| create(:issue, project: forager, github_number: number) }
    artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: "docs/rdrs/RDR-003-project-readiness-bootstrap.md", revision: "a" * 40,
      body: <<~MARKDOWN
        ## Related Issues

        | Owners | Work |
        | --- | --- |
        | viamin/Forager-iOS | [#4255](https://github.com/viamin/Forager-iOS/issues/4255), #4256 |
      MARKDOWN
    )
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return(discovery([ artifact ]))

    described_class.perform_now(project.id)

    expect(DesignArtifactFinding.count).to eq(0)
    expect(DesignArtifactAssociation.pluck(:issue_identity)).to contain_exactly(
      "viamin/Forager-iOS#4255", "viamin/Forager-iOS#4256"
    )
  end

  # @spec DESIGN-RECONCILIATION-001
  it "keeps mixed local and external ownership references distinct when issue numbers collide" do
    forager = create(:project, account: project.account, owner: "viamin", repo: "Forager-iOS")
    create(:issue, project:, github_number: 216)
    create(:issue, project:, github_number: 4256)
    [ 4256, 4325 ].each { |number| create(:issue, project: forager, github_number: number) }
    artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: "docs/rdrs/RDR-003-project-readiness-bootstrap.md", revision: "a" * 40,
      body: <<~MARKDOWN
        ## Related Issues
        - #216

        ## Issue ownership
        | Owner | Work |
        | --- | --- |
        | viamin/Forager-iOS | [#4255](https://github.com/viamin/Forager-iOS/issues/4325), #4256, docs/rdrs/RDR-074.md, https://example.com/spec#3 |
      MARKDOWN
    )
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return(discovery([ artifact ]))

    described_class.perform_now(project.id)

    expect(DesignArtifactFinding.count).to eq(0)
    expect(DesignArtifactAssociation.pluck(:issue_identity)).to contain_exactly(
      "acme/widget#216", "viamin/Forager-iOS#4256", "viamin/Forager-iOS#4325"
    )
  end

  # @spec DESIGN-RECONCILIATION-001
  it "does not treat a path in an ownership cell as an external repository" do
    create(:issue, project:, github_number: 4255)
    artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: "docs/rdrs/RDR-003-project-readiness-bootstrap.md", revision: "a" * 40,
      body: "## Ownership\n\n| Owner | Issue |\n| --- | --- |\n| docs/rdrs.md | #4255 |"
    )
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return(discovery([ artifact ]))

    described_class.perform_now(project.id)

    expect(DesignArtifactFinding.count).to eq(0)
    expect(DesignArtifactAssociation.sole.issue_identity).to eq("acme/widget#4255")
  end

  # @spec DESIGN-RECONCILIATION-001
  it "does not treat an external issue mentioned in ownership prose as declared evidence" do
    forager = create(:project, account: project.account, owner: "viamin", repo: "Forager-iOS")
    create(:issue, project: forager, github_number: 4255)
    artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: "docs/rdrs/RDR-003-project-readiness-bootstrap.md", revision: "a" * 40,
      body: "The issue owner mentioned viamin/Forager-iOS#4255 during discussion."
    )
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return(discovery([ artifact ]))

    described_class.perform_now(project.id)

    expect(DesignArtifactFinding.sole).to have_attributes(state: "missing_tree", status: "open")
    expect(DesignArtifactAssociation.count).to eq(0)
  end

  # @spec DESIGN-RECONCILIATION-001
  it "uses relationship references immediately following an ownership table" do
    artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: "docs/rdrs/RDR-020-service-container-architecture.md",
      revision: "a" * 40,
      body: <<~MARKDOWN
        ## Issue ownership
        | Owner | Work |
        | --- | --- |
        | Platform | Pending |
        ## Related Issues
        - #216
      MARKDOWN
    )
    create(:issue, project:, github_number: 216)
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return(discovery([ artifact ]))

    described_class.perform_now(project.id)

    expect(DesignArtifactFinding.count).to eq(0)
    expect(DesignArtifactAssociation.sole.issue_identity).to eq("acme/widget#216")
  end

  it "keeps denied external ownership coverage unverifiable rather than claiming local work is missing" do
    artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: "docs/rdrs/RDR-003-project-readiness-bootstrap.md", revision: "a" * 40,
      body: "## Ownership\n\n| Owner | Issue |\n| --- | --- |\n| denied/mobile | #4255 |"
    )
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return(discovery([ artifact ]))

    described_class.perform_now(project.id)

    expect(DesignArtifactFinding.sole).to have_attributes(state: "unverifiable", status: "open")
  end

  it "uses an exact issue backlink to reconcile an RDR without repairing the document" do
    artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: "docs/rdrs/RDR-020-service-container-architecture.md",
      revision: "a" * 40,
      body: "Status: Accepted"
    )
    create(:issue, project:, github_number: 216,
      body: "Implements docs/rdrs/RDR-020-service-container-architecture.md")
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return(discovery([ artifact ]))

    described_class.perform_now(project.id)

    expect(DesignArtifactFinding.count).to eq(0)
    expect(DesignArtifactAssociation.sole).to have_attributes(
      artifact_path: artifact.path, artifact_revision: artifact.revision,
      issue_identity: "acme/widget#216", provenance: "exact artifact backlink"
    )
  end

  it "does not use an exact backlink from another repository in the account" do
    artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: "docs/rdrs/RDR-020-service-container-architecture.md",
      revision: "a" * 40,
      body: "Status: Accepted"
    )
    other_project = create(:project, account: project.account, owner: "acme", repo: "other-widget")
    create(:issue, project: other_project, github_number: 216,
      body: "Implements docs/rdrs/RDR-020-service-container-architecture.md")
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return(discovery([ artifact ]))

    described_class.perform_now(project.id)

    expect(DesignArtifactFinding.sole).to have_attributes(
      artifact_path: artifact.path, revision: artifact.revision, state: "missing_tree", status: "open"
    )
    expect(DesignArtifactAssociation.count).to eq(0)
  end

  it "does not treat an untrusted issue backlink as structural evidence" do
    artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: "docs/rdrs/RDR-020-service-container-architecture.md",
      revision: "a" * 40,
      body: "Status: Accepted"
    )
    create(:issue, project:, github_number: 216, github_creator_login: "attacker",
      body: "Implements docs/rdrs/RDR-020-service-container-architecture.md")
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return(discovery([ artifact ]))

    described_class.perform_now(project.id)

    expect(DesignArtifactFinding.sole).to have_attributes(
      artifact_path: artifact.path, revision: artifact.revision, state: "missing_tree", status: "open"
    )
    expect(DesignArtifactAssociation.count).to eq(0)
  end

  it "does not treat an incidental artifact-path mention as an artifact backlink" do
    artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: "docs/rdrs/RDR-020-service-container-architecture.md",
      revision: "a" * 40,
      body: "Status: Accepted"
    )
    create(:issue, project:, github_number: 216,
      body: "We discussed `docs/rdrs/RDR-020-service-container-architecture.md` last week.")
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return(discovery([ artifact ]))

    described_class.perform_now(project.id)

    expect(DesignArtifactFinding.sole).to have_attributes(
      artifact_path: artifact.path, revision: artifact.revision, state: "missing_tree", status: "open"
    )
    expect(DesignArtifactAssociation.count).to eq(0)
  end

  it "does not treat an incidental issue mention as an issue-tree relationship" do
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number,
      body: "The prior discussion in #101 explains why this was deferred.")
    create(:issue, project:, github_number: 101)

    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.sole).to have_attributes(
      artifact_path: "pull/100", revision: design_pr.head_sha, state: "missing_tree", status: "open"
    )
  end

  it "treats an unmirrored cross-repository reference as unverifiable" do
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number, body: "Implements shared/platform#11")

    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.sole).to have_attributes(state: "unverifiable", artifact_path: "pull/100")
  end

  it "includes a locally mirrored cross-repository issue in coverage" do
    shared_project = create(:project, account: project.account, owner: "shared", repo: "platform")
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number, body: "Implements shared/platform#11")
    create(:issue, project: shared_project, github_number: 11)

    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.count).to eq(0)
  end

  it "resolves RDR findings removed from a successfully discovered directory" do
    finding = create(:design_artifact_finding, project:, account: project.account,
      artifact_path: "docs/rdrs/RDR-063-removed.md", revision: "a" * 40)
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return(discovery([]))

    described_class.perform_now(project.id)

    expect(finding.reload.status).to eq("resolved")
  end

  it "keeps RDR findings open when directory discovery is unverifiable" do
    finding = create(:design_artifact_finding, project:, account: project.account,
      artifact_path: "docs/rdrs/RDR-063-unknown.md", revision: "a" * 40)
    unavailable = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(path: "docs/rdrs", revision: "main", body: nil)
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return(discovery([ unavailable ], complete: false))

    described_class.perform_now(project.id)

    expect(finding.reload.status).to eq("open")
  end

  it "resolves the stale directory-level unavailable sentinel after successful empty discovery" do
    sentinel = create(:design_artifact_finding, project:, account: project.account,
      artifact_path: "docs/rdrs", revision: "main", state: "unverifiable")
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return(discovery([]))

    described_class.perform_now(project.id)

    expect(sentinel.reload).to have_attributes(status: "resolved", resolved_at: be_present)
  end

  it "does not resolve a prior finding for an unreadable individual artifact" do
    finding = create(:design_artifact_finding, project:, account: project.account,
      artifact_path: "docs/rdrs/RDR-063.md", revision: "a" * 40)
    unavailable = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: finding.artifact_path, revision: "b" * 40, body: nil
    )
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return(discovery([ unavailable ]))

    described_class.perform_now(project.id)

    expect(finding.reload.status).to eq("open")
    expect(project.design_artifact_findings.open_findings.pluck(:state)).to contain_exactly("missing_tree", "unverifiable")
  end
end
