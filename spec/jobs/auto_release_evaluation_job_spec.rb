# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe AutoReleaseEvaluationJob do
  let(:project) { create(:project, auto_release_granularity: "all") }
  let(:client) { instance_double(GithubClient) }

  let(:pr_data) do
    OpenStruct.new(
      number: 100,
      title: "chore(main): release 1.1.0",
      user: OpenStruct.new(login: "github-actions[bot]"),
      labels: [ OpenStruct.new(name: "autorelease: pending") ],
      head: OpenStruct.new(sha: "abc123"),
      merged_at: nil
    )
  end

  let(:manifest_content) do
    OpenStruct.new(content: Base64.encode64('{ ".": "1.0.0" }'))
  end

  let(:green_checks) do
    [ { conclusion: "success", name: "ci" } ]
  end

  before do
    allow(GithubClient).to receive(:new).and_return(client)
    allow(client).to receive_messages(
      pull_requests: [ pr_data ],
      pull_request: pr_data,
      contents: manifest_content,
      check_runs_for_ref: green_checks
    )
    allow(client).to receive(:merge_pull_request)
    allow(client).to receive(:add_labels_to_issue)
    allow(client).to receive(:add_comment)
  end

  describe "#perform" do
    it "merges a release PR when all conditions are met" do
      described_class.perform_now(project.id)

      expect(client).to have_received(:merge_pull_request).with(
        project.full_name, 100, merge_method: project.merge_method
      )
      expect(client).to have_received(:add_labels_to_issue).with(
        project.full_name, 100, [ "paid-auto-released" ]
      )
      expect(client).to have_received(:add_comment)
    end

    it "skips when project has auto_release_granularity off" do
      project.update!(auto_release_granularity: "off")

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "skips when bump type exceeds granularity (minor bump with patch_only)" do
      project.update!(auto_release_granularity: "patch_only")

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "merges patch bumps with patch_only granularity" do
      project.update!(auto_release_granularity: "patch_only")
      pr_data_patch = OpenStruct.new(
        number: 100,
        title: "chore(main): release 1.0.1",
        user: OpenStruct.new(login: "github-actions[bot]"),
        labels: [ OpenStruct.new(name: "autorelease: pending") ],
        head: OpenStruct.new(sha: "abc123"),
        merged_at: nil
      )
      allow(client).to receive_messages(pull_requests: [ pr_data_patch ], pull_request: pr_data_patch)

      described_class.perform_now(project.id)

      expect(client).to have_received(:merge_pull_request)
    end

    it "skips when CI checks are not green" do
      allow(client).to receive(:check_runs_for_ref).and_return(
        [ { conclusion: "failure", name: "ci" } ]
      )

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "skips when CI checks are pending (no conclusion)" do
      allow(client).to receive(:check_runs_for_ref).and_return(
        [ { conclusion: nil, name: "ci" } ]
      )

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "merges when no CI checks exist" do
      allow(client).to receive(:check_runs_for_ref).and_return([])

      described_class.perform_now(project.id)

      expect(client).to have_received(:merge_pull_request)
    end

    it "skips when no release PR is found" do
      allow(client).to receive(:pull_requests).and_return([])

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "accepts a specific pr_number parameter" do
      described_class.perform_now(project.id, pr_number: 100)

      expect(client).to have_received(:pull_request).with(project.full_name, 100)
      expect(client).to have_received(:merge_pull_request)
    end

    it "handles expected merge failures gracefully" do
      allow(client).to receive(:merge_pull_request).and_raise(
        GithubClient::ApiError.new("Merge conflict", status: 409)
      )

      expect { described_class.perform_now(project.id) }.not_to raise_error
    end

    context "with granularity matrix" do
      {
        "all" => { major: true, minor: true, patch: true },
        "major_only" => { major: true, minor: true, patch: true },
        "minor_only" => { major: false, minor: true, patch: true },
        "patch_only" => { major: false, minor: false, patch: true },
        "off" => { major: false, minor: false, patch: false }
      }.each do |granularity, bumps|
        bumps.each do |bump_type, should_merge|
          it "#{should_merge ? 'merges' : 'skips'} #{bump_type} bump with #{granularity} granularity" do
            project.update!(auto_release_granularity: granularity)

            version_map = { major: "2.0.0", minor: "1.1.0", patch: "1.0.1" }
            new_version = version_map[bump_type]

            pr = OpenStruct.new(
              number: 100,
              title: "chore(main): release #{new_version}",
              user: OpenStruct.new(login: "github-actions[bot]"),
              labels: [ OpenStruct.new(name: "autorelease: pending") ],
              head: OpenStruct.new(sha: "abc123"),
              merged_at: nil
            )
            allow(client).to receive_messages(pull_requests: [ pr ], pull_request: pr)

            described_class.perform_now(project.id)

            if should_merge
              expect(client).to have_received(:merge_pull_request)
            else
              expect(client).not_to have_received(:merge_pull_request)
            end
          end
        end
      end
    end
  end
end
