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

  before do
    allow(GithubClient).to receive(:new).and_return(client)
    allow(client).to receive(:add_comment)
    allow(client).to receive(:add_labels_to_issue)
    allow(client).to receive(:remove_label_from_issue)
    allow(client).to receive_messages(recent_issue_comments: [], remove_labels_from_issue: { removed: [], failed: [] })
  end

  describe "#execute" do
    context "when output_present is false (needs_input)" do
      it "sets issue paid_state to needs_input" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(issue.reload.paid_state).to eq("needs_input")
      end

      it "marks agent run as completed" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(agent_run.reload.status).to eq("completed")
      end

      it "adds the paid-needs-input label" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).to have_received(:add_labels_to_issue)
          .with(project.full_name, issue.github_number, [ "paid-needs-input" ])
      end

      it "posts a needs-input comment on the issue" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).to have_received(:add_comment)
          .with(project.full_name, issue.github_number, a_string_including("Needs Input"))
      end

      it "includes next-step instructions in the comment" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).to have_received(:add_comment)
          .with(project.full_name, issue.github_number,
            a_string_including("paid-needs-input").and(a_string_including("paid-build")))
      end

      it "logs the completion reason as needs_input" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        log = agent_run.agent_run_logs.find_by(log_type: "system")
        expect(log.content).to include("needs_input")
      end

      it "returns outcome needs_input" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        result = activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(result[:outcome]).to eq("needs_input")
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
    end

    context "when project uses automation label" do
      let(:auto_project) do
        create(:project,
          label_mappings: { "needs_input" => "paid-needs-input" },
          automation_on_label_enabled: true,
          automation_label_name: "my-auto")
      end

      it "references the automation label in the needs-input comment" do
        issue = create(:issue, :in_progress, project: auto_project)
        agent_run = create(:agent_run, :running, project: auto_project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).to have_received(:add_comment)
          .with(auto_project.full_name, issue.github_number, a_string_including("my-auto"))
      end

      it "removes the automation trigger label from the issue in batch" do
        issue = create(:issue, :in_progress, project: auto_project, labels: [ "my-auto" ])
        agent_run = create(:agent_run, :running, project: auto_project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).to have_received(:remove_labels_from_issue)
          .with(auto_project.full_name, issue.github_number, [ "my-auto" ])
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

      it "allows recommend_close when agent has cost_cents > 0" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 50)
        agent_run.log!("stdout", "This issue appears resolved already")

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("recommend_close")
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
        # needs_input (not recommend_close).
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", "The user reported a model not found bug last week")

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("needs_input")
      end

      it "classifies trivial output with zero iterations and zero cost as needs_input" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue,
          iterations: 0, cost_cents: 0)
        agent_run.log!("stdout", "OK.")

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("needs_input")
        expect(issue.reload.paid_state).to eq("needs_input")
      end
    end

    context "when an issue cycles through outcomes (label hygiene)" do
      it "clears a stale paid-recommend-close label when the next outcome is needs_input" do
        issue = create(:issue, :in_progress, project: project,
          labels: [ "paid-build", "paid-recommend-close" ])
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).to have_received(:remove_label_from_issue)
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

      it "redacts provider error lines from needs_input comments" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)
        agent_run.log!("stderr", "Some context\nrequires more credits\nMore context")

        result = activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(result[:outcome]).to eq("needs_input")

        expect(client).to have_received(:add_comment) do |_repo, _number, body|
          expect(body).to include("Needs Input")
          expect(body).not_to include("requires more credits")
        end
      end
    end

    context "when GitHub API returns errors" do
      it "completes the run even when comment posting fails" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        allow(client).to receive(:add_comment).and_raise(GithubClient::Error, "API error")

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(agent_run.reload.status).to eq("completed")
        expect(issue.reload.paid_state).to eq("needs_input")
      end

      it "completes the run even when label adding fails" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        allow(client).to receive(:add_labels_to_issue).and_raise(GithubClient::Error, "API error")

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(agent_run.reload.status).to eq("completed")
      end
    end
  end
end
