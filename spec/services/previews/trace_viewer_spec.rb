# frozen_string_literal: true

require "rails_helper"
require "aws-sdk-s3"

# @spec LIVE-PREVIEW-006
RSpec.describe Previews::TraceViewer, :no_db do
  let(:s3_client) { Aws::S3::Client.new(stub_responses: true) }
  let(:artifact_storage) { instance_double(ArtifactStorage, bucket: "paid-screenshots", client: s3_client, configured?: true) }
  let(:storage) { instance_double(Screenshots::Storage) }
  let(:viewer) { described_class.new(storage: storage, artifact_storage: artifact_storage) }

  let(:trace_params) { { org: "acme", repo: "web", pr_number: 42, commit_sha: "abc1234" } }

  before do
    allow(storage).to receive(:trace_object_key) do |org:, repo:, pr_number:, commit_sha:|
      "screenshots/#{org}/#{repo}/pr-#{pr_number}/#{commit_sha}/trace.zip"
    end
    allow(artifact_storage).to receive(:signed_url) do |key|
      "https://example.test/#{key}?X-Amz-Signature=abc"
    end
  end

  describe "#trace_object_key" do
    it "uses the storage trace key contract" do
      expect(viewer.trace_object_key(**trace_params))
        .to eq("screenshots/acme/web/pr-42/abc1234/trace.zip")
    end
  end

  describe "#trace_url" do
    it "returns a presigned URL for the trace object key" do
      expect(viewer.trace_url(**trace_params))
        .to eq("https://example.test/screenshots/acme/web/pr-42/abc1234/trace.zip?X-Amz-Signature=abc")
    end
  end

  describe "#viewer_index_url" do
    it "returns a presigned URL for the hosted viewer entry point" do
      expect(viewer.viewer_index_url)
        .to eq("https://example.test/trace-viewer/index.html?X-Amz-Signature=abc")
    end

    it "honors a custom viewer prefix" do
      custom = described_class.new(storage: storage, artifact_storage: artifact_storage, viewer_prefix: "custom-viewer")

      expect(custom.viewer_index_url)
        .to eq("https://example.test/custom-viewer/index.html?X-Amz-Signature=abc")
    end
  end

  describe "#viewer_url" do
    it "builds an embeddable URL with the trace appended as an escaped query param" do
      url = viewer.viewer_url(trace_url: "https://example.test/trace.zip?sig=a b")

      # The hosted viewer is a presigned S3 URL (already has a query string), so
      # the trace is appended with `&`.
      expect(url).to start_with("https://example.test/trace-viewer/index.html?X-Amz-Signature=abc&trace=")
      expect(url).to include("trace=https%3A%2F%2Fexample.test%2Ftrace.zip")
      # The trace URL is percent-encoded so it survives as a single query value.
      expect(url).not_to include(" ")
    end

    it "appends with a bare `?` when the viewer index URL has no query string" do
      allow(artifact_storage).to receive(:signed_url).and_return("https://example.test/trace-viewer/index.html")

      url = viewer.viewer_url(trace_url: "https://example.test/trace.zip")

      expect(url).to eq("https://example.test/trace-viewer/index.html?trace=https%3A%2F%2Fexample.test%2Ftrace.zip")
    end
  end

  describe "#embed_url" do
    it "combines the hosted viewer with a stored trace URL" do
      url = viewer.embed_url(**trace_params)

      expect(url)
        .to start_with("https://example.test/trace-viewer/index.html?X-Amz-Signature=abc&trace=")
      expect(url).to include("screenshots%2Facme%2Fweb%2Fpr-42%2Fabc1234%2Ftrace.zip")
    end
  end

  describe "#trace_available?" do
    it "returns true when the trace object exists" do
      s3_client.stub_responses(:head_object, {})

      expect(viewer.trace_available?(**trace_params)).to be(true)
    end

    it "returns false when the object is missing" do
      s3_client.stub_responses(:head_object, "NotFound")

      expect(viewer.trace_available?(**trace_params)).to be(false)
    end

    it "returns false on other S3 service errors so callers degrade gracefully" do
      s3_client.stub_responses(:head_object, "Forbidden")

      expect(viewer.trace_available?(**trace_params)).to be(false)
    end

    it "returns false when storage is not configured" do
      unconfigured = described_class.new(storage: storage, artifact_storage: artifact_storage)
      allow(artifact_storage).to receive(:configured?).and_return(false)

      expect(unconfigured.trace_available?(**trace_params)).to be(false)
      expect(s3_client).not_to receive(:head_object)
    end
  end

  describe "#upload_trace" do
    it "uploads the trace zip and returns a presigned URL" do
      file = Tempfile.new([ "trace", ".zip" ])
      file.write("fake trace zip")
      file.rewind
      allow(storage).to receive(:upload_trace)
        .with(file_path: file.path, **trace_params)
        .and_return("https://example.test/screenshots/acme/web/pr-42/abc1234/trace.zip?X-Amz-Signature=abc")

      url = viewer.upload_trace(file_path: file.path, **trace_params)

      expect(url).to eq("https://example.test/screenshots/acme/web/pr-42/abc1234/trace.zip?X-Amz-Signature=abc")
      expect(storage).to have_received(:upload_trace).with(file_path: file.path, **trace_params)
    ensure
      file.close
      file.unlink
    end

    it "raises TraceViewerError on S3 failure" do
      file = Tempfile.new([ "trace", ".zip" ])
      file.write("fake trace zip")
      file.rewind
      allow(storage).to receive(:upload_trace)
        .with(file_path: file.path, **trace_params)
        .and_raise(Screenshots::Storage::StorageError, "S3 trace upload failed: boom")

      expect { viewer.upload_trace(file_path: file.path, **trace_params) }
        .to raise_error(Previews::TraceViewer::TraceViewerError, /trace viewer upload failed/)
    ensure
      file.close
      file.unlink
    end
  end

  describe "#upload_viewer_assets!" do
    it "uploads every file under the viewer directory under the viewer prefix" do
      allow(s3_client).to receive(:put_object)
      Dir.mktmpdir("trace-viewer-src") do |dir|
        File.write(File.join(dir, "index.html"), "<html></html>")
        FileUtils.mkdir_p(File.join(dir, "assets"))
        File.write(File.join(dir, "assets", "app.js"), "console.log(1)")

        uploaded = viewer.upload_viewer_assets!(dir)

        expect(uploaded).to contain_exactly("trace-viewer/index.html", "trace-viewer/assets/app.js")
        expect(s3_client).to have_received(:put_object).at_least(:twice)
      end
    end

    it "raises TraceViewerError when the directory does not exist" do
      expect { viewer.upload_viewer_assets!("/nonexistent/viewer") }
        .to raise_error(Previews::TraceViewer::TraceViewerError, /viewer source dir not found/)
    end

    it "raises TraceViewerError when the directory has no files" do
      Dir.mktmpdir("trace-viewer-empty") do |dir|
        expect { viewer.upload_viewer_assets!(dir) }
          .to raise_error(Previews::TraceViewer::TraceViewerError, /no viewer assets found/)
      end
    end
  end

  describe "#configured?" do
    it "delegates to the artifact storage backend" do
      allow(artifact_storage).to receive(:configured?).and_return(true)
      expect(viewer.configured?).to be(true)

      allow(artifact_storage).to receive(:configured?).and_return(false)
      expect(viewer.configured?).to be(false)
    end
  end
end
