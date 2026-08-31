# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::HandleNoOutputIssueRunActivity do
  let(:activity) { described_class.new }
  let(:project) do
    create(:project,
      label_mappings: { "build" => "paid-build", "needs_input" => "paid-needs-input" },
      automation_on_label_enabled: false)
  end
  let(:client) { instance_double(GithubClient) }

  def gh_issue_response(project:, number:, id:, title:, body:)
    Struct.new(:number, :id, :title, :body, :state, :user, :labels, :created_at, :updated_at, :html_url).new(
      number,
      id,
      title,
      body,
      "open",
      Struct.new(:login).new("paid-bot"),
      [],
      Time.current,
      Time.current,
      "https://github.com/#{project.full_name}/issues/#{number}"
    )
  end

  before do
    allow(GithubClient).to receive(:new).and_return(client)
    allow(client).to receive(:add_comment)
    allow(client).to receive(:add_labels_to_issue)
    allow(client).to receive(:create_issue)
    allow(client).to receive(:remove_label_from_issue)
    allow(client).to receive(:update_issue)
    allow(client).to receive_messages(recent_issue_comments: [], remove_labels_from_issue: { removed: [], failed: [] })
  end

  describe "#execute" do
    context "when output_present is false" do
      it "sets issue paid_state to failed" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(issue.reload.paid_state).to eq("failed")
      end

      it "marks agent run as failed" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(agent_run.reload.status).to eq("failed")
      end

      it "does not add the paid-needs-input label" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).not_to have_received(:add_labels_to_issue)
          .with(project.full_name, issue.github_number, [ "paid-needs-input" ])
      end

      it "does not post a needs-input comment on the issue" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).not_to have_received(:add_comment)
          .with(project.full_name, issue.github_number, a_string_including("Needs Input"))
      end

      it "does not include needs-input next-step instructions in a comment" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).not_to have_received(:add_comment)
          .with(project.full_name, issue.github_number,
            a_string_including("paid-needs-input").and(a_string_including("paid-build")))
      end

      it "logs the failure reason as infrastructure_error" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        log = agent_run.agent_run_logs.find_by(log_type: "system")
        expect(log.content).to include("infrastructure")
      end

      it "returns outcome infrastructure_error" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        result = activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(result[:outcome]).to eq("infrastructure_error")
      end

      it "classifies hidden provider quota output as provider_error" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)
        agent_run.log!("stderr", "Free model usage limit reached. Please try again later.")

        result = activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(result[:outcome]).to eq("provider_error")
        expect(agent_run.reload.status).to eq("failed")
        expect(issue.reload.paid_state).to eq("failed")
      end

      it "classifies hidden infrastructure output as infrastructure_error" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)
        agent_run.log!("stderr", "bwrap: No permissions to create a new namespace")

        result = activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(result[:outcome]).to eq("infrastructure_error")
        expect(agent_run.reload.status).to eq("failed")
        expect(issue.reload.paid_state).to eq("failed")
      end

      it "classifies hidden provider output from the most recent logs" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        5.times { |i| agent_run.log!("stdout", "progress line #{i}") }
        agent_run.log!("stderr", "Free model usage limit reached. Please try again later.")

        result = activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(result[:outcome]).to eq("provider_error")
        expect(agent_run.reload.status).to eq("failed")
      end

      it "enqueues ProcessRunQueueJob" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        expect { activity.execute(agent_run_id: agent_run.id, output_present: false) }
          .to have_enqueued_job(ProcessRunQueueJob)
      end
    end

    context "when output_present is true (recommend_close)" do
      # @spec NO-OUTPUT-ISSUE-001
      it "sets issue paid_state to recommend_close" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 3, cost_cents: 100)

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(issue.reload.paid_state).to eq("recommend_close")
      end

      it "posts a recommend-close comment on the issue" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 3, cost_cents: 100)

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(client).to have_received(:add_comment)
          .with(project.full_name, issue.github_number, a_string_including("Recommend Close"))
      end

      it "does not add the paid-needs-input label" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 3, cost_cents: 100)

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(client).not_to have_received(:add_labels_to_issue)
          .with(project.full_name, issue.github_number, [ "paid-needs-input" ])
      end

      it "adds the paid-recommend-close label so the issue surfaces for human review" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 3, cost_cents: 100)

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(client).to have_received(:add_labels_to_issue)
          .with(project.full_name, issue.github_number, [ "paid-recommend-close" ])
      end

      it "uses the project-configured recommend_close label when set" do
        custom_project = create(:project,
          label_mappings: { "recommend_close" => "needs-review" },
          automation_on_label_enabled: false)
        issue = create(:issue, :in_progress, project: custom_project)
        agent_run = create(:agent_run, :running, project: custom_project, issue: issue,
          iterations: 3, cost_cents: 100)

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(client).to have_received(:add_labels_to_issue)
          .with(custom_project.full_name, issue.github_number, [ "needs-review" ])
      end

      it "returns outcome recommend_close" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 3, cost_cents: 100)

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("recommend_close")
      end

      it "removes the needs-input label if present" do
        issue = create(:issue, :in_progress, project: project, labels: [ "paid-needs-input" ])
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 3, cost_cents: 100)

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(client).to have_received(:remove_label_from_issue)
          .with(project.full_name, issue.github_number, "paid-needs-input")
      end

      it "does not attempt to remove needs-input label when not present" do
        issue = create(:issue, :in_progress, project: project, labels: [])
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 3, cost_cents: 100)

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(client).not_to have_received(:remove_label_from_issue)
          .with(project.full_name, issue.github_number, "paid-needs-input")
      end

      # @spec NO-OUTPUT-ISSUE-001
      it "records a surfaced failure when recommend-close comment posting fails" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 3, cost_cents: 100)
        allow(client).to receive(:add_comment).and_raise(GithubClient::Error, "comment rejected")

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(issue.reload.paid_state).to eq("recommend_close")
        expect(agent_run.reload.error_message).to include("Recommend-close explanation comment could not be posted")
        expect(agent_run.external_metadata["issue_explanation_comment_failure"]).to include(
          "issue_state" => "recommend_close",
          "marker" => "<!-- paid:recommend-close -->",
          "error" => "comment rejected"
        )
      end
    end

    context "when output_present is true and the agent emits a follow-up marker" do
      let(:parent_issue) { create(:issue, :in_progress, project: project, body: "Parent body") }
      let(:followup_title) { "Implement the missing gateway adapter" }
      let(:followup_body) { "The umbrella cannot close until the adapter exists." }
      let(:summary) do
        <<~SUMMARY
          The umbrella is blocked on missing implementation work.

          <!-- followup-title: #{followup_title} -->
          <!-- followup-body-start -->
          #{followup_body}
          <!-- followup-body-end -->
        SUMMARY
      end
      let(:agent_run) do
        create(:agent_run, :running, project: project, issue: parent_issue,
          iterations: 3, cost_cents: 100)
      end

      before do
        agent_run.log!("stdout", summary)
        allow(client).to receive(:create_issue).and_return(
          gh_issue_response(project:, number: 88, id: 8800, title: followup_title, body: followup_body)
        )
        allow(client).to receive(:update_issue)
      end

      # @spec NO-OUTPUT-ISSUE-003
      it "classifies the run as blocked_on_gap and creates a follow-up issue" do
        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("blocked_on_gap")
        followup = project.issues.find_by!(github_number: 88)
        expect(followup.title).to eq(followup_title)
        expect(followup.body).to eq(followup_body)
      end

      # @spec NO-OUTPUT-ISSUE-003
      it "writes an explicit dependency line into the parent and returns it to new" do
        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(client).to have_received(:update_issue).with(
          project.full_name,
          parent_issue.github_number,
          body: a_string_including("Depends on #88")
        )
        expect(parent_issue.reload.paid_state).to eq("new")
        expect(parent_issue.body).to include("Depends on #88")
        expect(parent_issue.dependencies.pluck(:github_number)).to eq([ 88 ])
      end

      # @spec NO-OUTPUT-ISSUE-003
      it "keeps the parent out of auto-pick until the follow-up closes, then makes it eligible again" do
        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(Issue.ready_for_work(project)).not_to include(parent_issue)
        expect(Issue.lifecycle_statuses([ parent_issue.reload ])[parent_issue.id]).to eq(:blocked)

        followup = project.issues.find_by!(github_number: 88)
        followup.update!(github_state: "closed")

        expect(Issue.ready_for_work(project)).to include(parent_issue.reload)
        expect(Issue.lifecycle_statuses([ parent_issue.reload ])[parent_issue.id]).to eq(:eligible)
      end

      # @spec NO-OUTPUT-ISSUE-005
      it "records an audit event for the follow-up creation" do
        expect {
          activity.execute(agent_run_id: agent_run.id, output_present: true)
        }.to change(AccountActivityEvent, :count).by(1)

        event = AccountActivityEvent.order(:id).last
        expect(event.action).to eq("agent_run.followup_issue_created")
        expect(event.subject).to eq(project.issues.find_by!(github_number: 88))
        expect(event.metadata).to include(
          "agent_run_id" => agent_run.id,
          "parent_issue_id" => parent_issue.id,
          "parent_github_number" => parent_issue.github_number,
          "followup_issue_id" => project.issues.find_by!(github_number: 88).id,
          "followup_github_number" => 88,
          "deduplicated" => false
        )
      end
    end

    context "when the follow-up marker is malformed or partial" do
      let(:issue) { create(:issue, :in_progress, project: project) }
      let(:agent_run) do
        create(:agent_run, :running, project: project, issue: issue,
          iterations: 3, cost_cents: 100)
      end

      before do
        agent_run.log!("stdout", <<~SUMMARY)
          The work is blocked.

          <!-- followup-title: Missing body -->
        SUMMARY
      end

      # @spec NO-OUTPUT-ISSUE-004
      it "falls back to recommend_close without creating a follow-up issue" do
        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("recommend_close")
        expect(project.issues.where.not(id: issue.id)).to be_empty
        expect(client).not_to have_received(:create_issue)
        expect(client).not_to have_received(:update_issue)
      end
    end

    context "when stray follow-up markers appear without a paired body block" do
      let(:issue) { create(:issue, :in_progress, project: project) }
      let(:agent_run) do
        create(:agent_run, :running, project: project, issue: issue,
          iterations: 3, cost_cents: 100)
      end

      # @spec NO-OUTPUT-ISSUE-004
      it "does not synthesize a follow-up plan from a stray title and a separate body block" do
        agent_run.log!("stdout", <<~SUMMARY)
          The work is blocked.

          <!-- followup-title: stray -->

          Some intermediate prose about why nothing shipped.

          <!-- followup-body-start -->
          This body should not be combined with the stray title above.
          <!-- followup-body-end -->
        SUMMARY

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("recommend_close")
        expect(client).not_to have_received(:create_issue)
        expect(client).not_to have_received(:update_issue)
        expect(issue.reload.paid_state).to eq("recommend_close")
        expect(project.issues.where.not(id: issue.id)).to be_empty
      end

      # @spec NO-OUTPUT-ISSUE-004
      it "rejects a stray body block that has no paired followup-title" do
        agent_run.log!("stdout", <<~SUMMARY)
          The work is blocked.

          <!-- followup-body-start -->
          A body with no paired title marker.
          <!-- followup-body-end -->
        SUMMARY

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("recommend_close")
        expect(client).not_to have_received(:create_issue)
      end
    end

    context "when a matching open follow-up issue already exists" do
      let(:parent_issue) { create(:issue, :in_progress, project: project, body: "Parent body") }
      let(:followup_title) { "Implement the missing gateway adapter" }
      let(:existing_followup) do
        create(:issue, project: project, title: followup_title, github_number: 88, body: "Existing body")
      end
      let(:agent_run) do
        create(:agent_run, :running, project: project, issue: parent_issue,
          iterations: 3, cost_cents: 100)
      end

      before do
        existing_followup
        agent_run.log!("stdout", <<~SUMMARY)
          <!-- followup-title: #{followup_title} -->
          <!-- followup-body-start -->
          New body that should not create a duplicate.
          <!-- followup-body-end -->
        SUMMARY
        allow(client).to receive(:update_issue)
      end

      # @spec NO-OUTPUT-ISSUE-005
      it "deduplicates against the open issue and avoids duplicating the parent dependency line on retry" do
        first = activity.execute(agent_run_id: agent_run.id, output_present: true)
        second = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(first[:outcome]).to eq("blocked_on_gap")
        expect(second[:outcome]).to eq("blocked_on_gap")
        expect(project.issues.where(title: followup_title).count).to eq(1)
        expect(client).not_to have_received(:create_issue)
        expect(parent_issue.reload.body.scan("Depends on #88").size).to eq(1)
      end
    end

    context "when multiple follow-up marker blocks are emitted" do
      let(:issue) { create(:issue, :in_progress, project: project, body: "Parent body") }
      let(:agent_run) do
        create(:agent_run, :running, project: project, issue: issue,
          iterations: 3, cost_cents: 100)
      end

      before do
        agent_run.log!("stdout", <<~SUMMARY)
          <!-- followup-title: First gap -->
          <!-- followup-body-start -->
          First body
          <!-- followup-body-end -->

          <!-- followup-title: Second gap -->
          <!-- followup-body-start -->
          Second body
          <!-- followup-body-end -->
        SUMMARY
        allow(client).to receive(:create_issue).and_return(
          gh_issue_response(project:, number: 91, id: 9100, title: "First gap", body: "First body")
        )
        allow(client).to receive(:update_issue)
      end

      # @spec NO-OUTPUT-ISSUE-005
      it "caps follow-up creation at one issue per run" do
        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(client).to have_received(:create_issue).once
        expect(project.issues.where.not(id: issue.id).pluck(:github_number)).to eq([ 91 ])
      end
    end

    context "when classification resolves to needs_input" do
      before do
        allow(activity).to receive(:classify_outcome).and_return("needs_input")
      end

      # @spec NO-OUTPUT-ISSUE-001
      it "records a surfaced failure when needs-input comment posting fails" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)
        allow(client).to receive(:add_comment).and_raise(GithubClient::Error, "comment rejected")

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(issue.reload.paid_state).to eq("needs_input")
        expect(agent_run.reload.error_message).to include("Needs-input explanation comment could not be posted")
        expect(agent_run.external_metadata["issue_explanation_comment_failure"]).to include(
          "issue_state" => "needs_input",
          "marker" => "<!-- paid:needs-input -->",
          "error" => "comment rejected"
        )
      end
    end

    context "when project uses automation label" do
      let(:auto_project) do
        create(:project,
          label_mappings: { "needs_input" => "paid-needs-input" },
          automation_on_label_enabled: true,
          automation_label_name: "my-auto")
      end

      it "does not post a needs-input comment for no-output failures" do
        issue = create(:issue, :in_progress, project: auto_project)
        agent_run = create(:agent_run, :running, project: auto_project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).not_to have_received(:add_comment)
          .with(auto_project.full_name, issue.github_number, a_string_including("my-auto"))
      end

      it "removes the automation trigger label for no-output failures" do
        issue = create(:issue, :in_progress, project: auto_project, labels: [ "my-auto" ])
        agent_run = create(:agent_run, :running, project: auto_project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).to have_received(:remove_labels_from_issue)
          .with(auto_project.full_name, issue.github_number, [ "my-auto" ])
      end

      it "keeps failed bookkeeping if trigger label removal fails" do
        issue = create(:issue, :in_progress, project: auto_project, labels: [ "my-auto" ])
        agent_run = create(:agent_run, :running, project: auto_project, issue: issue)
        allow(client).to receive(:remove_labels_from_issue).and_raise(GithubClient::Error, "API error")

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(agent_run.reload.status).to eq("failed")
        expect(issue.reload.paid_state).to eq("failed")
      end

      it "removes the automation trigger label on recommend_close in batch" do
        issue = create(:issue, :in_progress, project: auto_project, labels: [ "my-auto" ])
        agent_run = create(:agent_run, :running, project: auto_project, issue: issue,
          iterations: 3, cost_cents: 100)

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(client).to have_received(:remove_labels_from_issue)
          .with(auto_project.full_name, issue.github_number, [ "my-auto" ])
      end
    end

    context "when agent run has no issue" do
      it "marks the run completed without posting comments" do
        agent_run = create(:agent_run, :running, project: project, issue: nil,
          custom_prompt: "Test prompt")

        result = activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(agent_run.reload.status).to eq("completed")
        expect(result[:outcome]).to eq("no_changes")
        expect(client).not_to have_received(:add_comment)
      end
    end

    context "when a comment marker already exists" do
      it "skips posting needs-input comment if marker already exists" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        existing_comment = Struct.new(:body).new("<!-- paid:needs-input -->\nOld comment")
        allow(client).to receive(:recent_issue_comments).and_return([ existing_comment ])

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).not_to have_received(:add_comment)
      end

      it "skips posting recommend-close comment if marker already exists" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 3, cost_cents: 100)

        existing_comment = Struct.new(:body).new("<!-- paid:recommend-close -->\nOld comment")
        allow(client).to receive(:recent_issue_comments).and_return([ existing_comment ])

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(client).not_to have_received(:add_comment)
      end
    end

    context "when the handler is retried after the explanation comment succeeds" do
      # @spec NO-OUTPUT-ISSUE-002
      it "does not post a duplicate recommend-close comment and clears stale failure state" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 3, cost_cents: 100,
          error_message: "Recommend-close explanation comment could not be posted to GitHub. Review the run for details.",
          external_metadata: {
            "issue_explanation_comment_failure" => {
              "issue_state" => "recommend_close",
              "marker" => "<!-- paid:recommend-close -->",
              "error" => "comment rejected",
              "recorded_at" => "2026-08-31T00:00:00Z"
            }
          })
        existing_comment = Struct.new(:body).new("<!-- paid:recommend-close -->\nOld comment")
        allow(client).to receive(:recent_issue_comments).and_return([], [ existing_comment ])

        activity.execute(agent_run_id: agent_run.id, output_present: true)
        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(client).to have_received(:add_comment).once
        expect(agent_run.reload.error_message).to be_nil
        expect(agent_run.external_metadata["issue_explanation_comment_failure"]).to be_nil
      end
    end

    context "when output is present but agent did not actually run (provider error)" do
      let(:credit_error) do
        "Error: This request requires more credits, or fewer max_tokens. " \
          "You requested up to 32000 tokens, but can only afford 4744. " \
          "To increase, visit https://openrouter.ai/settings/credits and add more credits"
      end

      it "classifies as provider_error when iterations and cost are zero" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", credit_error)

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("provider_error")
      end

      it "fails the run instead of completing it" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", credit_error)

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(agent_run.reload.status).to eq("failed")
      end

      it "transitions issue to failed so it is retryable by auto-pick" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", credit_error)

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(issue.reload.paid_state).to eq("failed")
      end

      it "does not post a recommend-close comment on GitHub" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", credit_error)

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(client).not_to have_received(:add_comment)
          .with(project.full_name, issue.github_number, a_string_including("Recommend Close"))
      end

      it "enqueues ProcessRunQueueJob for retry" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", credit_error)

        expect { activity.execute(agent_run_id: agent_run.id, output_present: true) }
          .to have_enqueued_job(ProcessRunQueueJob)
      end

      it "allows recommend_close when agent has iterations > 0" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 5, cost_cents: 0)
        agent_run.log!("stdout", "The issue is already fixed in the codebase")

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("recommend_close")
      end

      it "classifies as infrastructure_error when iterations is zero even with cost > 0" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 50)
        agent_run.log!("stdout", "OK.")

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("infrastructure_error")
        expect(issue.reload.paid_state).to eq("failed")
      end

      it "detects quota exceeded errors" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", "Error: quota exceeded for this API key")

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("provider_error")
      end

      it "detects rate limit errors" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", "Error: rate limit exceeded, please retry later")

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("provider_error")
      end

      it "detects free model usage limit wording as a provider error" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", "Free model usage limit reached. Please try again later.")

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("provider_error")
      end

      it "detects provider errors from stderr even when stdout contains trivial output" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", "OK.")
        agent_run.log!("stderr", "Free model usage limit reached. Please try again later.")

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("provider_error")
      end

      it "detects weekly limit wording as a provider error" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", "Weekly/Monthly Limit Exhausted. Your limit will reset at 2026-05-18 11:22:32")

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("provider_error")
      end

      it "detects DeepSeek insufficient balance wording as a provider error" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", "> build · deepseek-v4-pro\nError: Insufficient Balance")

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("provider_error")
      end
    end

    context "when output is present but agent hit infrastructure errors" do
      let(:bwrap_error) do
        "I'm blocked by the local execution environment. " \
          "bwrap: No permissions to create a new namespace, likely because " \
          "the kernel does not allow non-privileged user namespaces."
      end

      it "classifies as infrastructure_error when iterations and cost are zero" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", bwrap_error)

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("infrastructure_error")
      end

      it "fails the run instead of completing it" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", bwrap_error)

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(agent_run.reload.status).to eq("failed")
      end

      it "transitions issue to failed so it is retryable by auto-pick" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", bwrap_error)

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(issue.reload.paid_state).to eq("failed")
      end

      it "detects sandbox error variants" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", "sandbox error: cannot create namespace")

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("infrastructure_error")
      end

      it "treats no-space-left runtime failures as infrastructure errors even after some work" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 22)
        agent_run.log!("stdout", <<~LOG)
          error https://registry.yarnpkg.com/@esbuild/openbsd-x64/-/openbsd-x64-0.28.0.tgz:
          Extracting tar content of undefined failed, the file appears to be corrupt:
          "ENOSPC: no space left on device, write"
        LOG

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("infrastructure_error")
        expect(agent_run.reload.status).to eq("failed")
        expect(issue.reload.paid_state).to eq("failed")
      end

      it "treats permission auto-rejects as infrastructure errors even after some work" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 22)
        agent_run.log!("stderr", "! permission requested: external_directory (/home/agent/.cache/yarn/*); auto-rejecting")
        agent_run.log!("stdout", "Error: The user rejected permission to use this specific tool call.")

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("infrastructure_error")
        expect(agent_run.reload.status).to eq("failed")
        expect(issue.reload.paid_state).to eq("failed")
      end

      it "does not treat a bare tool-permission rejection quote as infrastructure error" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 3, cost_cents: 100)
        agent_run.log!("stdout", <<~LOG)
          I found the prior failure note: "The user rejected permission to use this specific tool call."
          That appears to be from an earlier run and is not needed for this issue.
        LOG

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("recommend_close")
      end

      it "allows recommend_close when agent has iterations > 0 despite bwrap mention" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 3, cost_cents: 100)
        agent_run.log!("stdout", "Checked the code and bwrap config looks fine")

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("recommend_close")
      end

      it "detects opencode ProviderModelNotFoundError as infrastructure error" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", "Error: Model not found: glm-5.1/.\nProviderModelNotFoundError: ProviderModelNotFoundError")

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("infrastructure_error")
      end

      it "transitions misconfigured opencode runs to failed for auto-pick retry" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", "Error: Model not found: glm-5.1/.")

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(issue.reload.paid_state).to eq("failed")
        expect(agent_run.reload.status).to eq("failed")
      end

      it "does not match a bare 'model not found' phrase quoted in agent output" do
        # The colon in /Model not found:/ guards against false-positives on
        # natural-language mentions of the phrase that the agent might quote
        # back from issue bodies or web fetches. With zero iterations and
        # zero cost the agent did no real work, so the correct fallback is
        # infrastructure_error (not recommend_close).
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", "The user reported a model not found bug last week")

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("infrastructure_error")
      end

      it "classifies trivial output with zero iterations and zero cost as infrastructure_error" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", "OK.")

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("infrastructure_error")
        expect(issue.reload.paid_state).to eq("failed")
      end
    end

    context "when an issue cycles through outcomes (label hygiene)" do
      it "does not touch recommend-close labels for no-output failures" do
        issue = create(:issue, :in_progress, project: project,
          labels: [ "paid-build", "paid-recommend-close" ])
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).not_to have_received(:remove_label_from_issue)
          .with(project.full_name, issue.github_number, "paid-recommend-close")
      end

      it "skips remove_label_from_issue for paid-recommend-close when not present" do
        issue = create(:issue, :in_progress, project: project, labels: [ "paid-build" ])
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).not_to have_received(:remove_label_from_issue)
          .with(project.full_name, issue.github_number, "paid-recommend-close")
      end

      it "is re-applied (idempotent) when a re-run produces the same recommend_close outcome" do
        issue = create(:issue, :in_progress, project: project,
          labels: [ "paid-build", "paid-recommend-close" ])
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 3, cost_cents: 100)

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        # Same label is re-added; GitHub's add_labels_to_issue is idempotent.
        expect(client).to have_received(:add_labels_to_issue)
          .with(project.full_name, issue.github_number, [ "paid-recommend-close" ])
      end
    end

    context "when GitHub comment would contain provider error text" do
      it "redacts provider error lines from recommend_close comments" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 3, cost_cents: 100)
        agent_run.log!("stdout", "Some legitimate output\nError: quota exceeded\nMore output")

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(client).to have_received(:add_comment) do |_repo, _number, body|
          expect(body).to include("Recommend Close")
          expect(body).not_to include("quota exceeded")
        end
      end

      it "does not post needs-input comments for no-output failures" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)
        agent_run.log!("stderr", "Some context\nrequires more credits\nMore context")

        result = activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(result[:outcome]).to eq("infrastructure_error")
        expect(client).not_to have_received(:add_comment)
      end
    end

    context "when GitHub API returns errors" do
      it "fails the run without posting a needs-input comment" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        allow(client).to receive(:add_comment).and_raise(GithubClient::Error, "API error")

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).not_to have_received(:add_comment)
        expect(agent_run.reload.status).to eq("failed")
        expect(issue.reload.paid_state).to eq("failed")
      end

      it "fails the run without adding a needs-input label" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        allow(client).to receive(:add_labels_to_issue).and_raise(GithubClient::Error, "API error")

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).not_to have_received(:add_labels_to_issue)
        expect(agent_run.reload.status).to eq("failed")
      end
    end
  end
end
