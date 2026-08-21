# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Projects::EnsureStandardLabels do
  let(:github_client) { instance_double(GithubClient) }
  let(:github_token_stub) { Struct.new(:client).new(github_client) }
  let(:project_class) do
    Struct.new(:id, :full_name, :owner, :repo, :github_token,
               :generated_label_name, :automation_label_name,
               :enhance_issue_needs_input_label_name, :enhance_issue_enhanced_label_name,
               :effective_priority_labels, :label_mappings, keyword_init: true) do
      def label_for_stage(stage)
        (label_mappings || {})[stage.to_s]
      end
    end
  end
  let(:project) do
    project_class.new(
      id: 1,
      full_name: "test-owner/test-repo",
      owner: "test-owner",
      repo: "test-repo",
      github_token: github_token_stub,
      generated_label_name: "paid-generated",
      automation_label_name: "paid-automation",
      enhance_issue_needs_input_label_name: "paid-needs-input",
      enhance_issue_enhanced_label_name: "paid-enhanced",
      effective_priority_labels: { "P1" => "P1", "P2" => "P2", "P3" => "P3" },
      label_mappings: {}
    )
  end

  def make_label(name, color: "000000", description: "")
    OpenStruct.new(name: name, color: color, description: description)
  end

  describe ".call" do
    context "when all labels are missing" do
      before do
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([])
        allow(github_client).to receive(:create_label)
      end

      it "creates all standard labels" do
        result = described_class.call(project: project)

        expect(result.created).to contain_exactly("paid-generated", "paid-automation",
          "paid-needs-input", "paid-enhanced", "paid-recommend-close", "paid-paused",
          "paid-tests-ready-for-review", "paid-tests-approved", "paid-test-changes-requested",
          "P1", "P2", "P3")
        expect(result.existing).to be_empty
        expect(result.divergent).to be_empty
        expect(result.errors).to be_empty
      end

      it "calls create_label with correct parameters for each label" do
        described_class.call(project: project)

        expected_calls = {
          "paid-generated" => { color: "0e8a16", description: "Created by Paid" },
          "paid-automation" => { color: "1d76db", description: "Triggers Paid automation" },
          "paid-needs-input" => { color: "d876e3", description: "Paid needs answers before enhancing this issue again" },
          "paid-enhanced" => { color: "0e8a16", description: "Paid has added implementation context to this issue" },
          "paid-recommend-close" => { color: "fbca04", description: "Paid ran but produced no PR — human review needed" },
          "paid-paused" => { color: "5319e7", description: "Paused in Paid — excluded from issue auto-pick" },
          "paid-tests-ready-for-review" => { color: "fbca04", description: "Paid draft PR contains proposed tests and is waiting for test review" },
          "paid-tests-approved" => { color: "0e8a16", description: "Paid tests are approved; implementation may begin" },
          "paid-test-changes-requested" => { color: "d93f0b", description: "Paid tests need changes before implementation starts" },
          "P1" => { color: "d93f0b", description: "High priority" },
          "P2" => { color: "ff9800", description: "Medium priority" },
          "P3" => { color: "fbca04", description: "Low priority" }
        }

        expected_calls.each do |name, attrs|
          expect(github_client).to have_received(:create_label).with(
            "test-owner/test-repo", name: name, **attrs
          )
        end
      end
    end

    context "when all labels already exist with correct settings" do
      before do
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([
          make_label("paid-generated", color: "0e8a16", description: "Created by Paid"),
          make_label("paid-automation", color: "1d76db", description: "Triggers Paid automation"),
          make_label("paid-needs-input", color: "d876e3", description: "Paid needs answers before enhancing this issue again"),
          make_label("paid-enhanced", color: "0e8a16", description: "Paid has added implementation context to this issue"),
          make_label("paid-recommend-close", color: "fbca04", description: "Paid ran but produced no PR — human review needed"),
          make_label("paid-paused", color: "5319e7", description: "Paused in Paid — excluded from issue auto-pick"),
          make_label("paid-tests-ready-for-review", color: "fbca04", description: "Paid draft PR contains proposed tests and is waiting for test review"),
          make_label("paid-tests-approved", color: "0e8a16", description: "Paid tests are approved; implementation may begin"),
          make_label("paid-test-changes-requested", color: "d93f0b", description: "Paid tests need changes before implementation starts"),
          make_label("P1", color: "d93f0b", description: "High priority"),
          make_label("P2", color: "ff9800", description: "Medium priority"),
          make_label("P3", color: "fbca04", description: "Low priority")
        ])
      end

      it "is a no-op" do
        result = described_class.call(project: project)

        expect(result.created).to be_empty
        expect(result.existing).to contain_exactly("paid-generated", "paid-automation",
          "paid-needs-input", "paid-enhanced", "paid-recommend-close", "paid-paused",
          "paid-tests-ready-for-review", "paid-tests-approved", "paid-test-changes-requested",
          "P1", "P2", "P3")
        expect(result.divergent).to be_empty
        expect(result.errors).to be_empty
      end
    end

    context "when labels exist with different colors" do
      before do
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([
          make_label("paid-generated", color: "0e8a16", description: "Created by Paid"),
          make_label("paid-automation", color: "1d76db", description: "Triggers Paid automation"),
          make_label("paid-needs-input", color: "d876e3", description: "Paid needs answers before enhancing this issue again"),
          make_label("paid-enhanced", color: "0e8a16", description: "Paid has added implementation context to this issue"),
          make_label("paid-recommend-close", color: "fbca04", description: "Paid ran but produced no PR — human review needed"),
          make_label("paid-paused", color: "5319e7", description: "Paused in Paid — excluded from issue auto-pick"),
          make_label("paid-tests-ready-for-review", color: "fbca04", description: "Paid draft PR contains proposed tests and is waiting for test review"),
          make_label("paid-tests-approved", color: "0e8a16", description: "Paid tests are approved; implementation may begin"),
          make_label("paid-test-changes-requested", color: "d93f0b", description: "Paid tests need changes before implementation starts"),
          make_label("P1", color: "000000", description: "High priority"),
          make_label("P2", color: "ff9800", description: "Medium priority"),
          make_label("P3", color: "fbca04", description: "Low priority")
        ])
      end

      it "flags divergent labels without overwriting" do
        result = described_class.call(project: project)

        expect(result.created).to be_empty
        expect(result.divergent).to include(
          { name: "P1", field: "color", expected: "d93f0b", actual: "000000" }
        )
        expect(result.errors).to be_empty
      end
    end

    context "when the GitHub token lacks permissions to create labels" do
      before do
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([])
        allow(github_client).to receive(:create_label)
          .and_raise(GithubClient::ApiError.new("Resource not accessible by integration", status: 403))
      end

      it "records permission errors for each label" do
        result = described_class.call(project: project)

        expect(result.errors.size).to eq(12)
        result.errors.each do |err|
          expect(err[:error]).to include("Insufficient permissions")
        end
      end
    end

    context "when the GitHub token lacks permissions to read labels" do
      before do
        allow(github_client).to receive(:labels)
          .and_raise(GithubClient::ApiError.new("Resource not accessible by integration", status: 403))
      end

      it "raises with a clear permission error" do
        expect { described_class.call(project: project) }
          .to raise_error(GithubClient::ApiError, /Insufficient permissions to read labels/)
      end
    end

    context "when a label is created between fetch and create (422 race)" do
      before do
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([])
        allow(github_client).to receive(:create_label) do |_repo, name:, **|
          if name == "P1"
            raise GithubClient::ApiError.new("Validation Failed", status: 422)
          end
        end
      end

      it "treats the 422 as the label already existing" do
        result = described_class.call(project: project)

        expect(result.created).not_to include("P1")
        expect(result.errors).to be_empty
      end
    end

    context "with custom priority label names" do
      let(:project) do
        project_class.new(
          id: 1,
          full_name: "test-owner/test-repo",
          owner: "test-owner",
          repo: "test-repo",
          github_token: github_token_stub,
          generated_label_name: "paid-generated",
          automation_label_name: "paid-automation",
          enhance_issue_needs_input_label_name: "paid-needs-input",
          enhance_issue_enhanced_label_name: "paid-enhanced",
          effective_priority_labels: { "P1" => "critical", "P2" => "medium", "P3" => "low" },
          label_mappings: {}
        )
      end

      before do
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([])
        allow(github_client).to receive(:create_label)
      end

      it "creates labels with the custom names" do
        result = described_class.call(project: project)

        expect(result.created).to include("critical", "medium", "low")
      end
    end

    context "when label name matching is case-insensitive" do
      before do
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([
          make_label("Paid-Generated", color: "0e8a16", description: "Created by Paid"),
          make_label("PAID-AUTOMATION", color: "1d76db", description: "Triggers Paid automation"),
          make_label("PAID-NEEDS-INPUT", color: "d876e3", description: "Paid needs answers before enhancing this issue again"),
          make_label("PAID-ENHANCED", color: "0e8a16", description: "Paid has added implementation context to this issue"),
          make_label("PAID-RECOMMEND-CLOSE", color: "fbca04", description: "Paid ran but produced no PR — human review needed"),
          make_label("PAID-PAUSED", color: "5319e7", description: "Paused in Paid — excluded from issue auto-pick"),
          make_label("PAID-TESTS-READY-FOR-REVIEW", color: "fbca04", description: "Paid draft PR contains proposed tests and is waiting for test review"),
          make_label("PAID-TESTS-APPROVED", color: "0e8a16", description: "Paid tests are approved; implementation may begin"),
          make_label("PAID-TEST-CHANGES-REQUESTED", color: "d93f0b", description: "Paid tests need changes before implementation starts"),
          make_label("p1", color: "d93f0b", description: "High priority"),
          make_label("p2", color: "ff9800", description: "Medium priority"),
          make_label("p3", color: "fbca04", description: "Low priority")
        ])
      end

      it "treats differently-cased labels as existing" do
        result = described_class.call(project: project)

        expect(result.created).to be_empty
        expect(result.existing.size).to eq(12)
      end
    end

    context "when the project configures a custom recommend_close label" do
      let(:project) do
        project_class.new(
          id: 1,
          full_name: "test-owner/test-repo",
          owner: "test-owner",
          repo: "test-repo",
          github_token: github_token_stub,
          generated_label_name: "paid-generated",
          automation_label_name: "paid-automation",
          enhance_issue_needs_input_label_name: "paid-needs-input",
          enhance_issue_enhanced_label_name: "paid-enhanced",
          effective_priority_labels: { "P1" => "P1", "P2" => "P2", "P3" => "P3" },
          label_mappings: { "recommend_close" => "needs-review" }
        )
      end

      before do
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([])
        allow(github_client).to receive(:create_label)
      end

      it "provisions the configured label name instead of the default" do
        result = described_class.call(project: project)

        expect(result.created).to include("needs-review")
        expect(result.created).not_to include("paid-recommend-close")
      end
    end
  end

  describe "Result#notice_message" do
    it "summarizes created, existing, and divergent labels" do
      result = described_class::Result.new(
        created: [ "P1", "P2" ],
        existing: [ "paid-generated" ],
        divergent: [ { name: "paid-automation", field: "color", expected: "1d76db", actual: "000000" } ],
        errors: []
      )

      message = result.notice_message
      expect(message).to include("Created labels: P1, P2")
      expect(message).to include("1 label(s) already present")
      expect(message).to include("Labels with different settings: paid-automation")
    end

    it "reports errors" do
      result = described_class::Result.new(
        created: [],
        existing: [],
        divergent: [],
        errors: [ { name: "P1", error: "forbidden" } ]
      )

      expect(result.notice_message).to include("Failed to create: P1")
    end
  end
end
