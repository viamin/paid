# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::ScanPaidPrsActivity do
  describe "#review_feedback_resolution_scores", :no_db do
    let(:activity) { described_class.new }
    let(:project) { instance_double(ProjectDouble) }
    let(:client) { instance_double(GithubClientDouble) }
    let(:issue) { instance_double(IssueDouble) }
    let(:focused_run) { instance_double(AgentRunDouble) }
    let(:pr_data) { instance_double(PrDataDouble) }
    let(:checks) { [ { name: "ci", conclusion: "success" } ] }
    let(:reviews) { [ { user_login: "paid-code-reviewer[bot]", state: "COMMENTED" } ] }
    let(:unresolved_threads) { [] }

    before do
      stub_const("ProjectDouble", Class.new)
      stub_const("GithubClientDouble", Class.new)
      stub_const("IssueDouble", Class.new)
      stub_const("AgentRunDouble", Class.new)
      stub_const("PrDataDouble", Class.new)
      allow(activity).to receive(:fetch_pr_data).with(client, project, issue).and_return(pr_data)
      allow(activity).to receive(:fetch_check_runs).with(client, project, pr_data).and_return(checks)
      allow(activity).to receive(:fetch_reviews).with(client, project, issue).and_return(reviews)
      allow(activity).to receive(:fetch_unresolved_threads).with(client, project, issue).and_return(unresolved_threads)
      allow(activity).to receive(:human_review_thread_triggers)
        .with(project, unresolved_threads, issue: issue, client: client)
        .and_return([])
      allow(activity).to receive(:check_non_enabled_bot_reviews)
        .with(reviews, unresolved_threads, project:, last_run: focused_run, client:, issue:)
        .and_return([])
      allow(activity).to receive(:changes_requested_from_reviews).with(project, reviews, focused_run).and_return([])
      allow(activity).to receive(:check_conversation_comments).with(client, project, issue, focused_run).and_return([])
      allow(activity).to receive(:non_bot_review_gate_triggers)
        .with(project, issue, pr_data, reviews, checks)
        .and_return([])
    end

    it "returns 0.0 when body-only review feedback is still pending" do
      allow(activity).to receive(:check_review_bot_status)
        .with(reviews, unresolved_threads, project:, last_run: focused_run, client:, issue:)
        .and_return([ { type: "review_bot_comments" } ])

      result = activity.send(:review_feedback_resolution_scores, project, client, issue, focused_run)

      expect(result).to eq("focus_resolved" => 0.0)
    end

    it "returns 1.0 when no review feedback signals remain" do
      allow(activity).to receive(:check_review_bot_status)
        .with(reviews, unresolved_threads, project:, last_run: focused_run, client:, issue:)
        .and_return([])

      result = activity.send(:review_feedback_resolution_scores, project, client, issue, focused_run)

      expect(result).to eq("focus_resolved" => 1.0)
    end

    it "defers attribution when required review data cannot be fetched" do
      allow(activity).to receive(:fetch_reviews).with(client, project, issue).and_return(nil)

      result = activity.send(:review_feedback_resolution_scores, project, client, issue, focused_run)

      expect(result).to be_nil
    end
  end

  describe "#human_review_thread_triggers", :no_db do
    def stub_docs_only_planning_diff(client, project, issue)
      allow(client).to receive(:pull_request_files)
        .with(project.full_name, issue.github_number)
        .and_return([
          "docs/intent/lid-pr-confirmation/lid-pr-confirmation-design.md",
          "docs/intent/lid-pr-confirmation/lid-pr-confirmation-specs.md",
          "AGENTS.md"
        ])
      allow(client).to receive(:pull_request)
        .with(project.full_name, issue.github_number)
        .and_return(PullRequestDouble.new(HeadDouble.new("abc123")))
      allow(client).to receive(:file_content)
        .with(project.full_name, path: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-design.md", ref: "abc123")
        .and_return("## Decisions\n\n- Confirmed later [inferred]\n")
      allow(client).to receive(:file_content)
        .with(project.full_name, path: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-specs.md", ref: "abc123")
        .and_return("## Open Questions\n\n- Which decision needs confirmation?\n")
      allow(client).to receive(:file_content)
        .with(project.full_name, path: "AGENTS.md", ref: "abc123")
        .and_return("Agent instructions\n")
    end

    let(:activity) { described_class.new }
    let(:project) { instance_double(ProjectDouble, full_name: "acme/widgets") }
    let(:client) { instance_double(GithubClientDouble) }
    let(:issue) { instance_double(IssueDouble, github_number: 42) }
    let(:unresolved_threads) do
      [
        {
          id: "thread_1",
          is_resolved: false,
          comments: [
            { body: "Please fix this", author: "trusteduser" }
          ]
        }
      ]
    end

    before do
      stub_const("ProjectDouble", Class.new)
      stub_const("GithubClientDouble", Class.new)
      stub_const("IssueDouble", Class.new)
      stub_const("HeadDouble", Struct.new(:sha))
      stub_const("PullRequestDouble", Struct.new(:head))
      allow(project).to receive(:trusted_github_user?).with("trusteduser").and_return(true)
    end

    it "suppresses unresolved thread triggers while the live diff remains docs-only" do
      stub_docs_only_planning_diff(client, project, issue)

      triggers = activity.send(
        :human_review_thread_triggers,
        project,
        unresolved_threads,
        issue: issue,
        client: client
      )

      expect(triggers).to eq([])
    end

    it "treats stale planning markers as ordinary review feedback once code files are added" do
      allow(client).to receive(:pull_request_files)
        .with(project.full_name, issue.github_number)
        .and_return([
          "docs/intent/lid-pr-confirmation/lid-pr-confirmation-design.md",
          "app/services/prompts/build_for_pr.rb"
        ])

      triggers = activity.send(
        :human_review_thread_triggers,
        project,
        unresolved_threads,
        issue: issue,
        client: client
      )

      expect(triggers).to eq([ { type: "review_threads", details: "1 unresolved thread(s)" } ])
    end
  end
end
