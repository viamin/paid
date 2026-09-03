# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# @spec GH-LABELS-001 @spec GH-LABELS-002 @spec GH-LABELS-003 @spec GH-LABELS-004 @spec GH-LABELS-005 @spec GH-LABELS-007 @spec GH-LABELS-008
RSpec.describe Projects::EnsureStandardLabels do
  let(:github_client) { instance_double(GithubClient) }
  let(:github_token_stub) { Struct.new(:client).new(github_client) }
  let(:project_class) do
    Struct.new(:id, :full_name, :owner, :repo, :github_token,
               :generated_label_name, :automation_label_name,
               :enhance_issue_needs_input_label_name, :enhance_issue_enhanced_label_name,
               :effective_priority_labels, :effective_auto_pick_skip_labels,
               :effective_feature_activation_labels, :label_mappings, keyword_init: true) do
      def label_for_stage(stage)
        (label_mappings || {})[stage.to_s]
      end

      def feature_activation_label_for(feature)
        (effective_feature_activation_labels || {})[feature.to_s]
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
      effective_auto_pick_skip_labels: AutoPickSkipLabels::DEFAULTS,
      effective_feature_activation_labels: FeatureActivationLabels::DEFAULTS,
      label_mappings: {}
    )
  end

  # The full canonical set provisioned for the default project stub above:
  # 4 configurable + recommend_close + 9 fixed control/status labels + 10
  # activation labels + 3 TDD labels + 6 default auto-pick skip labels + 3
  # priority tiers. (The
  # needs_input stage mapping defaults to the same name as
  # enhance_issue_needs_input_label_name, so it is not a distinct entry here.)
  def all_label_names
    %w[
      paid-generated paid-automation paid-needs-input paid-enhanced paid-recommend-close
      paid-in-full paid-enhance paid-auto-merge paid-scan paid-scan-security paid-fix-conflicts
      paid-auto-release paid-tdd-strict paid-tdd-auto
      paid-paused paid-escalated paid-dismiss-escalation paid-skip-auto-merge
      paid-auto-merged paid-auto-merged-dependabot paid-auto-released paid-ready model-health
      paid-tests-ready-for-review paid-tests-approved paid-test-changes-requested
      planning research waiting tracking epic needs-manual-setup
      P1 P2 P3
    ]
  end

  def make_label(name, color: "000000", description: "")
    OpenStruct.new(name: name, color: color, description: description)
  end

  def expected_definitions
    {
      "paid-generated" => { color: "0e8a16", description: "Created by Paid" },
      "paid-automation" => { color: "1d76db", description: "Triggers Paid automation for this issue; remove to opt out." },
      "paid-needs-input" => { color: "d876e3", description: "Paid needs answers before enhancing this issue again" },
      "paid-enhanced" => { color: "0e8a16", description: "Paid has added implementation context to this issue" },
      "paid-in-full" => { color: "0052cc", description: "Activates Paid through PR for this issue; auto-merge still requires PR approval." },
      "paid-enhance" => { color: "0052cc", description: "Activates issue enhancement for this item when the project setting is off." },
      "paid-auto-merge" => { color: "0052cc", description: "Activates Paid auto-merge for this pull request when the project setting is off." },
      "paid-scan" => { color: "0052cc", description: "Activates Paid PR scanning for this pull request when the project setting is off." },
      "paid-scan-security" => { color: "0052cc", description: "Activates Paid security scanning for this pull request when the project setting is off." },
      "paid-fix-conflicts" => { color: "0052cc", description: "Activates Paid merge-conflict fixing for this pull request when the project setting is off." },
      "paid-auto-release" => { color: "0052cc", description: "Activates Paid auto-release for this pull request when the project setting is off." },
      "paid-tdd-strict" => { color: "0052cc", description: "Activates strict TDD for this issue when the project setting is off." },
      "paid-tdd-auto" => { color: "0052cc", description: "Activates non-strict TDD for this issue when the project setting is off." },
      "paid-recommend-close" => { color: "fbca04", description: "Paid ran but produced no PR — human review needed" },
      "paid-paused" => { color: "5319e7", description: "Pauses Paid automation on this issue; remove to resume." },
      "paid-escalated" => { color: "b60205", description: "Applied by Paid to pause automation for human review; remove to resume." },
      "paid-dismiss-escalation" => { color: "c2e0c6", description: "Alternate escalation-dismissed marker; cleared automatically by Paid." },
      "paid-skip-auto-merge" => { color: "e99695", description: "Blocks Paid from automatically merging this pull request." },
      "paid-auto-merged" => { color: "0e8a16", description: "Applied by Paid after automatically merging this pull request." },
      "paid-auto-merged-dependabot" => { color: "0e8a16", description: "Applied by Paid after automatically merging this Dependabot pull request." },
      "paid-auto-released" => { color: "0e8a16", description: "Applied by Paid after automatically merging this release pull request." },
      "paid-ready" => { color: "0e8a16", description: "Applied by Paid when a pull request is marked ready for review." },
      "model-health" => { color: "5319e7", description: "Flags provider model drift or broken runner models. Informational only." },
      "paid-tests-ready-for-review" => { color: "fbca04", description: "Tests are ready for review; implementation is blocked until approved." },
      "paid-tests-approved" => { color: "0e8a16", description: "Tests approved — Paid may begin implementation." },
      "paid-test-changes-requested" => { color: "d93f0b", description: "Test changes requested; implementation is blocked until resolved." },
      "planning" => { color: "bfd4f2", description: "Excludes this issue from Paid auto-pick while planning is in progress." },
      "research" => { color: "bfd4f2", description: "Excludes this issue from Paid auto-pick while research is in progress." },
      "waiting" => { color: "bfd4f2", description: "Excludes this issue from Paid auto-pick while it waits on something else." },
      "tracking" => { color: "bfd4f2", description: "Excludes this issue from Paid auto-pick; tracking/meta issue, not actionable." },
      "epic" => { color: "bfd4f2", description: "Excludes this issue from Paid auto-pick; epic/parent issue, not directly actionable." },
      "needs-manual-setup" => { color: "bfd4f2", description: "Excludes this issue from Paid auto-pick until manual setup is completed." },
      "P1" => { color: "d93f0b", description: "High priority" },
      "P2" => { color: "ff9800", description: "Medium priority" },
      "P3" => { color: "fbca04", description: "Low priority" }
    }
  end

  describe ".call" do
    context "when all labels are missing" do
      before do
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([])
        allow(github_client).to receive(:create_label)
      end

      it "creates every canonical label" do
        result = described_class.call(project: project)

        expect(result.created).to match_array(all_label_names)
        expect(result.existing).to be_empty
        expect(result.reconciled).to be_empty
        expect(result.errors).to be_empty
      end

      it "calls create_label with the canonical color and description for each label" do
        described_class.call(project: project)

        expected_definitions.each do |name, attrs|
          expect(github_client).to have_received(:create_label).with(
            "test-owner/test-repo", name: name, **attrs
          )
        end
      end
    end

    context "when all labels already exist with correct settings" do
      before do
        labels = expected_definitions.map { |name, attrs| make_label(name, **attrs) }
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return(labels)
      end

      it "is a no-op" do
        result = described_class.call(project: project)

        expect(result.created).to be_empty
        expect(result.existing).to match_array(all_label_names)
        expect(result.reconciled).to be_empty
        expect(result.errors).to be_empty
      end

      it "is idempotent across repeated calls" do
        first = described_class.call(project: project)
        second = described_class.call(project: project)

        expect(second.created).to eq(first.created)
        expect(second.existing).to eq(first.existing)
        expect(second.reconciled).to eq(first.reconciled)
        expect(second.errors).to eq(first.errors)
      end
    end

    context "when a label exists with a different color" do
      before do
        labels = expected_definitions.map { |name, attrs| make_label(name, **attrs) }
        labels.find { |l| l.name == "P1" }.color = "000000"
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return(labels)
        allow(github_client).to receive(:update_label)
      end

      it "reconciles the color via a GitHub label update instead of only reporting it" do
        result = described_class.call(project: project)

        expect(result.created).to be_empty
        expect(result.reconciled).to include({ name: "P1", fields: [ "color" ] })
        expect(github_client).to have_received(:update_label).with(
          "test-owner/test-repo", "P1", color: "d93f0b", description: "High priority"
        )
        expect(result.errors).to be_empty
      end
    end

    context "when a Paid-owned label exists with a stale description" do
      before do
        labels = expected_definitions.map { |name, attrs| make_label(name, **attrs) }
        labels.find { |l| l.name == "paid-escalated" }.description = "An old, undocumented description"
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return(labels)
        allow(github_client).to receive(:update_label)
      end

      it "reconciles the stale description" do
        result = described_class.call(project: project)

        expect(result.reconciled).to include({ name: "paid-escalated", fields: [ "description" ] })
        expect(github_client).to have_received(:update_label).with(
          "test-owner/test-repo", "paid-escalated",
          color: "b60205",
          description: "Applied by Paid to pause automation for human review; remove to resume."
        )
      end
    end

    context "when reconciling a label fails due to insufficient permissions" do
      before do
        labels = expected_definitions.map { |name, attrs| make_label(name, **attrs) }
        labels.find { |l| l.name == "P1" }.color = "000000"
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return(labels)
        allow(github_client).to receive(:update_label)
          .and_raise(GithubClient::ApiError.new("Resource not accessible by integration", status: 403))
      end

      it "records an actionable error instead of silently leaving the label stale" do
        result = described_class.call(project: project)

        expect(result.reconciled).to be_empty
        expect(result.errors).to contain_exactly(
          { name: "P1", error: "Insufficient permissions to update labels. Ensure the GitHub token has repo scope." }
        )
        expect(result.any_errors?).to be true
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

        expect(result.errors.size).to eq(all_label_names.size)
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

    # @spec GH-LABELS-008
    context "when a label is created between fetch and create (422 race)" do
      before do
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([])
        allow(github_client).to receive(:create_label) do |_repo, name:, **|
          if name == "P1"
            raise GithubClient::ApiError.new("Validation Failed", status: 422)
          end
        end
        allow(github_client).to receive(:label).with("test-owner/test-repo", "P1")
          .and_return(make_label("P1", color: "d93f0b", description: "High priority"))
      end

      it "treats a verified 422 as the label already existing" do
        result = described_class.call(project: project)

        expect(result.created).not_to include("P1")
        expect(result.existing).to include("P1")
        expect(result.errors).to be_empty
      end
    end

    # @spec GH-LABELS-008
    context "when a 422 create failure is a validation failure" do
      before do
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([])
        allow(github_client).to receive(:create_label) do |_repo, name:, **|
          if name == "P1"
            raise GithubClient::ApiError.new("Validation Failed", status: 422)
          end
        end
        allow(github_client).to receive(:label).with("test-owner/test-repo", "P1")
          .and_raise(GithubClient::NotFoundError)
      end

      it "records an error instead of treating the 422 as a race win" do
        result = described_class.call(project: project)

        expect(result.created).not_to include("P1")
        expect(result.existing).not_to include("P1")
        expect(result.errors).to contain_exactly({ name: "P1", error: "Validation Failed" })
        expect(result.any_errors?).to be true
      end
    end

    # @spec GH-LABELS-008
    context "when the post-422 verification fetch itself fails" do
      before do
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([])
        allow(github_client).to receive(:create_label) do |_repo, name:, **|
          if name == "P1"
            raise GithubClient::ApiError.new("Validation Failed", status: 422)
          end
        end
        allow(github_client).to receive(:label).with("test-owner/test-repo", "P1")
          .and_raise(GithubClient::ApiError.new("Server Error", status: 500))
      end

      it "records the original failure rather than assuming the label exists" do
        result = described_class.call(project: project)

        expect(result.existing).not_to include("P1")
        expect(result.errors).to contain_exactly({ name: "P1", error: "Validation Failed" })
        expect(result.any_errors?).to be true
      end
    end

    context "when a label is deleted between fetch and update (404 race)" do
      before do
        labels = expected_definitions.map { |name, attrs| make_label(name, **attrs) }
        labels.find { |l| l.name == "P1" }.color = "000000"
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return(labels)
        allow(github_client).to receive(:update_label) do |_repo, name, **|
          raise GithubClient::NotFoundError if name == "P1"
        end
      end

      it "records an error instead of aborting the whole sync" do
        result = described_class.call(project: project)

        expect(result.reconciled.map { |r| r[:name] }).not_to include("P1")
        expect(result.errors).to include(
          name: "P1",
          error: a_string_including("was deleted during the sync")
        )
        expect(result.any_errors?).to be true
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
          effective_auto_pick_skip_labels: AutoPickSkipLabels::DEFAULTS,
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

    context "with a project-configured custom auto-pick skip label" do
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
          effective_auto_pick_skip_labels: [ "on-hold" ],
          label_mappings: {}
        )
      end

      before do
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([])
        allow(github_client).to receive(:create_label)
      end

      it "provisions the custom name with the generic skip-label description" do
        result = described_class.call(project: project)

        expect(result.created).to include("on-hold")
        expect(github_client).to have_received(:create_label).with(
          "test-owner/test-repo", name: "on-hold", color: "bfd4f2",
          description: "Excludes this issue from Paid auto-pick while applied."
        )
      end
    end

    context "when label name matching is case-insensitive" do
      before do
        labels = expected_definitions.map { |name, attrs| make_label(name.upcase, **attrs) }
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return(labels)
      end

      it "treats differently-cased labels as existing" do
        result = described_class.call(project: project)

        expect(result.created).to be_empty
        expect(result.existing.size).to eq(all_label_names.size)
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
          effective_auto_pick_skip_labels: AutoPickSkipLabels::DEFAULTS,
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

    context "when the project configures a custom needs_input stage label" do
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
          effective_auto_pick_skip_labels: AutoPickSkipLabels::DEFAULTS,
          label_mappings: { "needs_input" => "no-output-needs-input" }
        )
      end

      before do
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([])
        allow(github_client).to receive(:create_label)
      end

      it "provisions both the enhance-issue label and the diverged stage label" do
        result = described_class.call(project: project)

        expect(result.created).to include("paid-needs-input", "no-output-needs-input")
        expect(result.errors).to be_empty
      end
    end

    context "when the needs_input stage label is unconfigured and shares the enhance-issue default" do
      before do
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([])
        allow(github_client).to receive(:create_label)
      end

      it "provisions paid-needs-input once instead of reporting a collision" do
        result = described_class.call(project: project)

        expect(result.created.count("paid-needs-input")).to eq(1)
        expect(result.errors).to be_empty
      end
    end

    # @spec GH-LABELS-007
    context "when configured label names collide with a fixed category label" do
      let(:project) do
        project_class.new(
          id: 1,
          full_name: "test-owner/test-repo",
          owner: "test-owner",
          repo: "test-repo",
          github_token: github_token_stub,
          generated_label_name: "paid-auto-merged",
          automation_label_name: "paid-automation",
          enhance_issue_needs_input_label_name: "paid-needs-input",
          enhance_issue_enhanced_label_name: "paid-enhanced",
          effective_priority_labels: { "P1" => "P1", "P2" => "P2", "P3" => "P3" },
          effective_auto_pick_skip_labels: AutoPickSkipLabels::DEFAULTS,
          label_mappings: {}
        )
      end

      before do
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([])
        allow(github_client).to receive(:create_label)
        allow(github_client).to receive(:update_label)
      end

      it "records a collision error naming every category that claims the label" do
        result = described_class.call(project: project)

        expect(result.errors).to include(
          a_hash_including(
            name: "paid-auto-merged",
            error: match(/paid-auto-merged.*generated_label_name.*PAID_AUTO_MERGED_LABEL/m)
          )
        )
        expect(result.any_errors?).to be true
      end

      it "does not create or reconcile the colliding label" do
        result = described_class.call(project: project)

        expect(result.created).not_to include("paid-auto-merged")
        expect(result.reconciled.map { |r| r[:name] }).not_to include("paid-auto-merged")
        expect(github_client).not_to have_received(:create_label)
          .with(anything, hash_including(name: "paid-auto-merged"))
        expect(github_client).not_to have_received(:update_label)
          .with(anything, "paid-auto-merged", any_args)
      end

      it "still provisions every non-colliding canonical label" do
        result = described_class.call(project: project)

        expect(result.created).to include("paid-automation", "paid-paused", "P1", "P2")
      end
    end

    # @spec GH-LABELS-007
    context "when a configured label name collides with another configured label case-insensitively" do
      let(:project) do
        project_class.new(
          id: 1,
          full_name: "test-owner/test-repo",
          owner: "test-owner",
          repo: "test-repo",
          github_token: github_token_stub,
          generated_label_name: "Shared-Label",
          automation_label_name: "paid-automation",
          enhance_issue_needs_input_label_name: "paid-needs-input",
          enhance_issue_enhanced_label_name: "shared-label",
          effective_priority_labels: { "P1" => "P1", "P2" => "P2", "P3" => "P3" },
          effective_auto_pick_skip_labels: AutoPickSkipLabels::DEFAULTS,
          label_mappings: {}
        )
      end

      before do
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([])
        allow(github_client).to receive(:create_label)
        allow(github_client).to receive(:update_label)
      end

      it "records a collision error naming both configurable categories" do
        result = described_class.call(project: project)

        collision = result.errors.find { |e| e[:name].casecmp?("shared-label") }
        expect(collision).not_to be_nil
        expect(collision[:error]).to match(/shared-label.*generated_label_name.*enhance_issue_enhanced_label_name/im)
      end

      it "does not PATCH the shared label into whichever definition ran last" do
        described_class.call(project: project)

        expect(github_client).not_to have_received(:create_label)
          .with(anything, hash_including(name: "shared-label"))
        expect(github_client).not_to have_received(:create_label)
          .with(anything, hash_including(name: "Shared-Label"))
      end
    end

    # @spec GH-LABELS-007
    context "when two priority tiers map to the same label name" do
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
          effective_priority_labels: { "P1" => "shared", "P2" => "shared", "P3" => "P3" },
          effective_auto_pick_skip_labels: AutoPickSkipLabels::DEFAULTS,
          label_mappings: {}
        )
      end

      before do
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([])
        allow(github_client).to receive(:create_label)
        allow(github_client).to receive(:update_label)
      end

      it "records a collision error naming both priority tiers" do
        result = described_class.call(project: project)

        collision = result.errors.find { |e| e[:name] == "shared" }
        expect(collision).not_to be_nil
        expect(collision[:error]).to match(/priority_label\[P1\].*priority_label\[P2\]/i)
      end

      it "does not create or reconcile the colliding label" do
        result = described_class.call(project: project)

        expect(result.created).not_to include("shared")
        expect(github_client).not_to have_received(:create_label)
          .with(anything, hash_including(name: "shared"))
      end
    end

    context "when the repository has unrelated, non-canonical labels" do
      before do
        labels = [ make_label("bug", color: "d73a4a", description: "Something isn't working") ]
        allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return(labels)
        allow(github_client).to receive(:create_label)
        allow(github_client).to receive(:update_label)
      end

      it "never creates or reconciles a label outside the canonical set" do
        result = described_class.call(project: project)

        expect(result.created + result.existing + result.reconciled.map { |r| r[:name] }).not_to include("bug")
        expect(github_client).not_to have_received(:create_label).with(anything, hash_including(name: "bug"))
        expect(github_client).not_to have_received(:update_label).with(anything, "bug", any_args)
      end
    end
  end

  describe "LABEL_DEFINITIONS" do
    it "keeps every description within GitHub's 100-character label limit" do
      described_class::LABEL_DEFINITIONS.except(:priority).each_value do |definition|
        expect(definition[:description].length).to be <= 100
      end
      described_class::AUTO_PICK_SKIP_LABEL_DESCRIPTIONS.each_value do |description|
        expect(description.length).to be <= 100
      end
      expect(described_class::AUTO_PICK_SKIP_LABEL_DEFAULT_DESCRIPTION.length).to be <= 100
    end

    it "tags every top-level definition with a control/status/informational kind" do
      described_class::LABEL_DEFINITIONS.except(:priority).each_value do |definition|
        expect(definition[:kind]).to be_in(%i[control status informational])
      end
    end
  end

  describe ".call_best_effort" do
    # @spec GH-LABELS-001
    it "delegates to .call and returns its result" do
      allow(github_client).to receive(:labels).with("test-owner/test-repo").and_return([])
      allow(github_client).to receive(:create_label)

      result = described_class.call_best_effort(project: project)

      expect(result).to be_a(described_class::Result)
      expect(github_client).to have_received(:labels).with("test-owner/test-repo")
    end

    # @spec GH-LABELS-001
    it "rescues a labels-list failure and logs a warning instead of raising" do
      allow(github_client).to receive(:labels).with("test-owner/test-repo")
        .and_raise(GithubClient::ApiError.new("Forbidden", status: 403))
      logger = instance_double(Logger, warn: nil)

      result = described_class.call_best_effort(project: project, logger: logger)

      expect(result).to be_nil
      expect(logger).to have_received(:warn).with(hash_including(project_id: project.id))
    end

    # GithubClient#handle_errors re-raises raw Faraday::Error after recording
    # the health failure. A transport-level timeout during the labels-list call
    # must not propagate to the calling job/activity — the primary state
    # change has already succeeded.
    it "rescues a Faraday transport error and logs a warning instead of raising" do
      allow(github_client).to receive(:labels).with("test-owner/test-repo")
        .and_raise(Faraday::TimeoutError, "execution expired")
      logger = instance_double(Logger, warn: nil)

      result = described_class.call_best_effort(project: project, logger: logger)

      expect(result).to be_nil
      expect(logger).to have_received(:warn).with(hash_including(project_id: project.id))
    end
  end

  describe "Result#notice_message" do
    it "summarizes created, existing, and reconciled labels" do
      result = described_class::Result.new(
        created: [ "P1", "P2" ],
        existing: [ "paid-generated" ],
        reconciled: [ { name: "paid-automation", fields: [ "color" ] } ],
        errors: []
      )

      message = result.notice_message
      expect(message).to include("Created labels: P1, P2")
      expect(message).to include("1 label(s) already present")
      expect(message).to include("Reconciled labels: paid-automation")
    end

    it "reports errors" do
      result = described_class::Result.new(
        created: [],
        existing: [],
        reconciled: [],
        errors: [ { name: "P1", error: "forbidden" } ]
      )

      expect(result.notice_message).to include("Failed to sync: P1")
    end
  end
end
