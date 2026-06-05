# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClarifyingQuestions::ClearNeedsInput, :no_db do
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

  describe ".call" do
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
end
