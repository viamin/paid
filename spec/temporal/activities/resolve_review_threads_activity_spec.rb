# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ResolveReviewThreadsActivity do
  let(:project) { create(:project) }
  let(:agent_run) do
    create(:agent_run, :running,
      project: project,
      source_pull_request_number: 42,
      custom_prompt: "Fix PR")
  end
  let(:github_client) { instance_double(GithubClient) }
  let(:activity) { described_class.new }
  let(:assessed_thread) do
    { id: "thread_1", is_resolved: false,
      comments: [ { body: "Validate input", author: "viamin", created_at: "2026-11-22T03:00:00Z" } ] }
  end
  let(:thread_versions) { { "thread_1" => ReviewThreads::ContentDigest.call(assessed_thread) } }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  describe "#execute" do
    context "when there are unresolved threads" do
      before do
        allow(github_client).to receive(:review_threads)
          .with(project.full_name, 42)
          .and_return([
            { id: "thread_1", is_resolved: false, comments: [] },
            { id: "thread_2", is_resolved: true, comments: [] },
            { id: "thread_3", is_resolved: false, comments: [] }
          ])

        allow(github_client).to receive(:resolve_review_threads_batch)
          .and_return(resolved: %w[thread_1 thread_3], failed: [])
      end

      it "resolves unresolved threads in a single batch call" do
        expect(github_client).to receive(:resolve_review_threads_batch)
          .with(%w[thread_1 thread_3])

        activity.execute(agent_run_id: agent_run.id)
      end

      it "returns resolved and failed counts" do
        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:resolved_count]).to eq(2)
        expect(result[:failed_count]).to eq(0)
        expect(result[:agent_run_id]).to eq(agent_run.id)
      end

      it "resolves only requested thread ids when provided" do
        allow(github_client).to receive(:resolve_review_threads_batch)
          .with([ "thread_3" ])
          .and_return(resolved: %w[thread_3], failed: [])

        result = activity.execute(agent_run_id: agent_run.id, thread_ids: [ "thread_3", "missing" ])

        expect(result[:requested_thread_ids]).to eq([ "thread_3", "missing" ])
        expect(result[:resolved_count]).to eq(1)
      end

      it "leaves findings open when the head advanced after assessment" do
        allow(github_client).to receive(:pull_request_ref_oids).with(project.full_name, 42)
          .and_return(base: "base-sha", head: "new-head")
        expect(github_client).not_to receive(:resolve_review_threads_batch)

        result = activity.execute(agent_run_id: agent_run.id, thread_ids: [ "thread_1" ], expected_head_sha: "assessed-head")

        expect(result).to include(stale_head: true, resolved_count: 0)
      end

      # @spec FOCUSED-RUN-011
      it "leaves findings open when the head advances while fetching current threads" do
        allow(github_client).to receive(:pull_request_ref_oids).with(project.full_name, 42)
          .and_return({ base: "base-sha", head: "assessed-head" }, { base: "base-sha", head: "new-head" })
        allow(github_client).to receive(:review_threads).with(project.full_name, 42).and_return([ assessed_thread ])
        expect(github_client).not_to receive(:resolve_review_threads_batch)

        result = activity.execute(
          agent_run_id: agent_run.id,
          thread_ids: [ "thread_1" ],
          expected_head_sha: "assessed-head",
          thread_versions: thread_versions
        )

        expect(result).to include(stale_head: true, resolved_count: 0)
      end

      # @spec FOCUSED-RUN-011
      it "leaves a finding open when its thread changed after assessment" do
        changed_thread = assessed_thread.deep_dup
        changed_thread[:comments] << {
          body: "Also require an authorization check", author: "viamin", created_at: "2026-11-22T03:01:00Z"
        }
        allow(github_client).to receive(:pull_request_ref_oids).with(project.full_name, 42)
          .and_return(base: "base-sha", head: "assessed-head")
        allow(github_client).to receive(:review_threads).with(project.full_name, 42).and_return([ changed_thread ])
        expect(github_client).not_to receive(:resolve_review_threads_batch)

        result = activity.execute(
          agent_run_id: agent_run.id,
          thread_ids: [ "thread_1" ],
          expected_head_sha: "assessed-head",
          thread_versions: thread_versions
        )

        expect(result).to include(stale_threads: true, resolved_count: 0)
      end

      it "leaves a finding open when assessed thread versions are missing" do
        allow(github_client).to receive(:pull_request_ref_oids).with(project.full_name, 42)
          .and_return(base: "base-sha", head: "assessed-head")
        expect(github_client).not_to receive(:resolve_review_threads_batch)

        result = activity.execute(
          agent_run_id: agent_run.id,
          thread_ids: [ "thread_1" ],
          expected_head_sha: "assessed-head"
        )

        expect(result).to include(stale_threads: true, resolved_count: 0)
      end

      # @spec FOCUSED-RUN-011
      it "resolves a finding when its assessed head and thread version are unchanged" do
        expect(github_client).not_to receive(:pull_request)
        allow(github_client).to receive(:pull_request_ref_oids).with(project.full_name, 42)
          .and_return(base: "base-sha", head: "assessed-head")
        allow(github_client).to receive(:review_threads).with(project.full_name, 42).and_return([ assessed_thread ])
        allow(github_client).to receive(:resolve_review_threads_batch).with([ "thread_1" ])
          .and_return(resolved: [ "thread_1" ], failed: [])

        result = activity.execute(
          agent_run_id: agent_run.id,
          thread_ids: [ "thread_1" ],
          expected_head_sha: "assessed-head",
          thread_versions: thread_versions
        )

        expect(result).to include(resolved_count: 1, failed_count: 0)
      end
    end

    context "when individual thread resolution fails" do
      before do
        allow(github_client).to receive(:review_threads)
          .with(project.full_name, 42)
          .and_return([
            { id: "thread_1", is_resolved: false, comments: [] },
            { id: "thread_2", is_resolved: false, comments: [] }
          ])

        allow(github_client).to receive(:resolve_review_threads_batch)
          .with(%w[thread_1 thread_2])
          .and_return(
            resolved: %w[thread_1],
            failed: [ { id: "thread_2", error: "GraphQL error" } ]
          )
      end

      it "continues despite individual failures" do
        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:resolved_count]).to eq(1)
        expect(result[:failed_count]).to eq(1)
      end
    end

    context "when there are no unresolved threads" do
      before do
        allow(github_client).to receive(:review_threads)
          .with(project.full_name, 42)
          .and_return([
            { id: "thread_1", is_resolved: true, comments: [] }
          ])

        allow(github_client).to receive(:resolve_review_threads_batch)
          .with([])
          .and_return(resolved: [], failed: [])
      end

      it "returns zero counts" do
        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:resolved_count]).to eq(0)
        expect(result[:failed_count]).to eq(0)
      end
    end
  end
end
