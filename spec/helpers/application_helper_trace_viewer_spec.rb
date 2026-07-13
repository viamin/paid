# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper, type: :helper do
  describe "#agent_run_trace_viewer_data" do
    let(:project) { Struct.new(:owner, :repo).new("acme", "web") }
    let(:trace_viewer) { instance_double(Previews::TraceViewer) }

    def run_with(status:, pr_number:, result_commit_sha:, base_commit_sha: nil)
      Struct.new(:project, :pull_request_number, :result_commit_sha, :base_commit_sha, :status, keyword_init: true) do
        def finished? = status == "completed"
      end.new(
        project: project,
        pull_request_number: pr_number,
        result_commit_sha: result_commit_sha,
        base_commit_sha: base_commit_sha,
        status: status
      )
    end

    before do
      allow(Previews::TraceViewer).to receive(:new).and_return(trace_viewer)
    end

    context "when the run is finished and a trace exists" do
      let(:agent_run) { run_with(status: "completed", pr_number: 42, result_commit_sha: "abc1234") }
      let(:embed_url) { "https://example.test/trace-viewer/index.html&trace=..." }

      it "returns the embed URL" do
        allow(trace_viewer).to receive_messages(configured?: true, trace_available?: true, embed_url: embed_url)

        result = helper.agent_run_trace_viewer_data(agent_run)

        expect(trace_viewer).to have_received(:trace_available?).with(
          org: "acme", repo: "web", pr_number: 42, commit_sha: "abc1234"
        )
        expect(result).to eq({ available: true, embed_url: embed_url })
      end
    end

    context "when the run is finished but no trace exists" do
      let(:agent_run) { run_with(status: "completed", pr_number: 42, result_commit_sha: "abc1234") }

      it "returns unavailable without an embed URL" do
        allow(trace_viewer).to receive_messages(configured?: true, trace_available?: false)

        result = helper.agent_run_trace_viewer_data(agent_run)

        expect(result).to eq({ available: false, embed_url: nil })
      end
    end

    context "when the run is still running" do
      let(:agent_run) { run_with(status: "running", pr_number: 42, result_commit_sha: "abc1234") }

      it "returns unavailable without checking storage" do
        allow(trace_viewer).to receive(:configured?).and_return(true)
        allow(trace_viewer).to receive(:trace_available?)

        result = helper.agent_run_trace_viewer_data(agent_run)

        expect(result).to eq({ available: false, embed_url: nil })
        expect(trace_viewer).not_to have_received(:trace_available?)
      end
    end

    context "when trace storage is not configured" do
      let(:agent_run) { run_with(status: "completed", pr_number: 42, result_commit_sha: "abc1234") }

      it "returns unavailable without checking S3" do
        allow(trace_viewer).to receive(:configured?).and_return(false)
        allow(trace_viewer).to receive(:trace_available?)

        result = helper.agent_run_trace_viewer_data(agent_run)

        expect(result).to eq({ available: false, embed_url: nil })
        expect(trace_viewer).not_to have_received(:trace_available?)
      end
    end

    context "when the run has no PR or result commit" do
      it "returns unavailable when there is no PR number" do
        agent_run = run_with(status: "completed", pr_number: nil, result_commit_sha: "abc1234")
        allow(trace_viewer).to receive(:configured?).and_return(true)

        expect(helper.agent_run_trace_viewer_data(agent_run)).to eq({ available: false, embed_url: nil })
      end

      it "returns unavailable when there is no commit sha" do
        agent_run = run_with(status: "completed", pr_number: 42, result_commit_sha: nil, base_commit_sha: nil)
        allow(trace_viewer).to receive(:configured?).and_return(true)

        expect(helper.agent_run_trace_viewer_data(agent_run)).to eq({ available: false, embed_url: nil })
      end
    end

    context "when a transient error occurs resolving the trace" do
      let(:agent_run) { run_with(status: "completed", pr_number: 42, result_commit_sha: "abc1234") }

      it "degrades gracefully to unavailable" do
        allow(trace_viewer).to receive(:configured?).and_raise(StandardError, "boom")

        expect(helper.agent_run_trace_viewer_data(agent_run)).to eq({ available: false, embed_url: nil })
      end
    end
  end
end
