# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClarifyingQuestions::ClearNeedsInput do
  describe ".call", :no_db do
    let(:github_client) { instance_double(GithubClient, remove_label_from_issue: nil) }
    let(:project) do
      double(
        client: github_client,
        full_name: "paid/app",
        enhance_issue_needs_input_label_name: "paid-needs-input"
      )
    end
    let(:issue) do
      double(
        github_number: 1964,
        needs_input?: true,
        labels: [ "paid-needs-input", "P2" ],
        update!: true
      )
    end

    it "removes the needs-input label on GitHub" do
      described_class.call(project: project, issue: issue)

      expect(github_client).to have_received(:remove_label_from_issue).with(
        "paid/app", 1964, "paid-needs-input"
      )
    end

    it "resets paid_state and drops the label locally" do
      described_class.call(project: project, issue: issue)

      expect(issue).to have_received(:update!).with(paid_state: "new", labels: [ "P2" ])
    end

    context "when the issue is not awaiting input" do
      let(:issue) { double(needs_input?: false) }

      it "is a no-op" do
        described_class.call(project: project, issue: issue)

        expect(github_client).not_to have_received(:remove_label_from_issue)
      end
    end

    context "when the project has no GitHub client" do
      before { allow(project).to receive(:client).and_return(nil) }

      it "still resets local state" do
        described_class.call(project: project, issue: issue)

        expect(issue).to have_received(:update!).with(paid_state: "new", labels: [ "P2" ])
      end
    end

    context "when removing the GitHub label fails" do
      before do
        allow(github_client).to receive(:remove_label_from_issue)
          .and_raise(GithubClient::Error.new("boom"))
      end

      it "logs and still resets local state" do
        described_class.call(project: project, issue: issue)

        expect(issue).to have_received(:update!).with(paid_state: "new", labels: [ "P2" ])
      end
    end
  end

  describe "create_feature needs-input flow" do
    let(:project) { create(:project) }
    let(:issue) do
      create(:issue, :needs_input, project: project,
             title: "[Feature] Add dark mode", body: "Users want dark mode")
    end
    let(:github_client) { instance_double(GithubClient, remove_label_from_issue: nil, issue_comments: []) }

    before do
      allow(project).to receive(:client).and_return(github_client)
      allow(ProcessRunQueueJob).to receive(:perform_later)
    end

    context "when the issue has a paused create_feature run" do
      let!(:agent_run) do
        create(:agent_run, :create_feature_goal, project: project, issue: issue,
               status: "paused",
               external_metadata: {
                 "feature_brief" => { "title" => "Add dark mode", "problem" => "Need dark theme" }
               })
      end

      it "resumes the paused create_feature run" do
        expect { described_class.call(project: project, issue: issue) }
          .to change { agent_run.reload.status }.from("paused").to("queued")
      end

      it "merges the assembled feature brief into external_metadata" do
        described_class.call(project: project, issue: issue)

        brief = agent_run.reload.external_metadata["feature_brief"]
        expect(brief).to be_present
        expect(brief["title"]).to eq("Add dark mode")
        expect(brief["problem"]).to eq("Users want dark mode")
      end

      it "does not reset paid_state to new" do
        described_class.call(project: project, issue: issue)
        expect(issue.reload.paid_state).to eq("needs_input")
      end
    end

    context "when the issue has no paused create_feature run" do
      it "resets paid_state to new normally" do
        described_class.call(project: project, issue: issue)
        expect(issue.reload.paid_state).to eq("new")
      end
    end
  end

  describe "#assemble_feature_brief_from_answers" do
    let(:project) { create(:project) }
    let(:issue) do
      create(:issue, :needs_input, project: project,
             title: "[Feature] Add dark mode", body: "Users want dark mode")
    end

    let(:user_double) { double(login: "viamin") }
    let(:enhancement_comment) do
      double(
        body: +"<!-- paid:enhance-issue -->\n\n## Clarifying questions\n\n" \
              "1. What is the desired behavior?\n" \
              "2. What constraints must be respected?\n" \
              "3. What alternatives have been considered and rejected?\n" \
              "4. What is in scope and out of scope?\n" \
              "5. How will we know it's done?",
        user: user_double,
        created_at: 1.hour.ago
      )
    end

    let(:answer_comment) do
      double(
        body: +"<!-- paid:clarifying-answers -->\n\n" \
              "## Clarifying question answers\n\n" \
              "**Q1: What is the desired behavior?**\n" \
              "**A1:** Toggle dark mode in settings\n\n" \
              "**Q2: What constraints must be respected?**\n" \
              "**A2:** Must work with SSR\n\n" \
              "**Q3: What alternatives have been considered and rejected?**\n" \
              "**A3:** CSS-only approach\n\n" \
              "**Q4: What is in scope and out of scope?**\n" \
              "**A4:** Color palette and toggle\n\n" \
              "**Q5: How will we know it's done?**\n" \
              "**A5:** Visual regression tests pass",
        user: user_double,
        created_at: Time.current
      )
    end

    let(:github_client) { instance_double(GithubClient) }

    before do
      allow(project).to receive(:trusted_github_user?).with("viamin").and_return(true)
      allow(project).to receive_messages(github_credential_present?: true, client: github_client)
      allow(github_client).to receive(:issue_comments)
        .and_return([ enhancement_comment, answer_comment ])
    end

    it "builds a complete brief from answer pairs" do
      service = described_class.new(project: project, issue: issue)
      brief = service.send(:assemble_feature_brief_from_answers, issue)

      expect(brief["title"]).to eq("Add dark mode")
      expect(brief["problem"]).to eq("Users want dark mode")
      expect(brief["desired_behavior"]).to eq("Toggle dark mode in settings")
      expect(brief["constraints"]).to include("Must work with SSR")
      expect(brief["rejected_alternatives"]).to eq("CSS-only approach")
      expect(brief["scope"]).to eq({ "in" => "Color palette and toggle", "out" => "" })
      expect(brief["done_criteria"]).to eq("Visual regression tests pass")
    end
  end
end
