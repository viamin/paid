# frozen_string_literal: true

require "rails_helper"
require "aws-sdk-s3"

RSpec.describe Screenshots::Storage, :no_db do
  let(:s3_client) { Aws::S3::Client.new(stub_responses: true) }
  let(:storage) { described_class.new(bucket: "test-bucket", region: "us-east-1") }

  before do
    allow(storage.artifact_storage).to receive_messages(
      client: s3_client,
      presigner: Aws::S3::Presigner.new(client: s3_client)
    )
  end

  def trace_tempfile
    file = Tempfile.new([ "trace", ".zip" ])
    file.write("fake trace data")
    file.rewind
    yield file
  ensure
    file&.close
    file&.unlink
  end

  def video_tempfile
    file = Tempfile.new([ "capture", ".webm" ])
    file.write("fake video data")
    file.rewind
    yield file
  ensure
    file&.close
    file&.unlink
  end

  describe "delegation to the shared ArtifactStorage module" do
    # @spec ARTIFACT-STORAGE-003
    it "exposes the shared S3 client instead of constructing its own" do
      shared_client = Aws::S3::Client.new(stub_responses: true)
      storage = described_class.new(bucket: "shared-bucket", region: "us-west-2")

      allow(storage.artifact_storage).to receive(:client).and_return(shared_client)

      expect(storage.s3_client).to be(shared_client)
      expect(storage.artifact_storage).to be_an(ArtifactStorage)
    end

    it "shares bucket and region resolution with ArtifactStorage" do
      storage = described_class.new(bucket: "shared-bucket", region: "us-west-2")

      expect(storage.bucket).to eq("shared-bucket")
      expect(storage.region).to eq("us-west-2")
      expect(storage.bucket).to eq(storage.artifact_storage.bucket)
    end

    it "class-level configured? mirrors ArtifactStorage.configured?" do
      expect(described_class.configured?).to eq(ArtifactStorage.configured?)
    end
  end

  describe "#object_key" do
    it "builds the correct S3 key path" do
      key = storage.object_key(
        org: "acme",
        repo: "web",
        pr_number: 42,
        commit_sha: "abc1234",
        route_name: "dashboard"
      )

      expect(key).to eq("screenshots/acme/web/pr-42/abc1234/dashboard.png")
    end
  end

  describe "#trace_object_key" do
    it "builds the trace S3 key path" do
      expect(storage.trace_object_key(org: "acme", repo: "web", pr_number: 42, commit_sha: "abc1234"))
        .to eq("screenshots/acme/web/pr-42/abc1234/trace.zip")
    end
  end

  describe "#video_object_key" do
    it "builds the video S3 key path" do
      expect(storage.video_object_key(org: "acme", repo: "web", pr_number: 42, commit_sha: "abc1234"))
        .to eq("screenshots/acme/web/pr-42/abc1234/capture.webm")
    end
  end

  describe "#upload" do
    it "uploads a file to S3 and returns a presigned URL" do
      file = Tempfile.new([ "screenshot", ".png" ])
      file.write("fake png data")
      file.rewind

      s3_client.stub_responses(:put_object, {})
      allow(storage).to receive(:signed_url).and_return("https://example.test/uploaded.png?X-Amz-Signature=123")

      url = storage.upload(
        file_path: file.path,
        org: "acme",
        repo: "web",
        pr_number: 42,
        commit_sha: "abc1234",
        route_name: "dashboard"
      )

      expect(url).to eq("https://example.test/uploaded.png?X-Amz-Signature=123")
      expect(storage).to have_received(:signed_url).with("screenshots/acme/web/pr-42/abc1234/dashboard.png")
    ensure
      file.close
      file.unlink
    end

    it "raises StorageError on S3 failure" do
      file = Tempfile.new([ "screenshot", ".png" ])
      file.write("fake png data")
      file.rewind

      s3_client.stub_responses(:put_object, "ServiceError")

      expect {
        storage.upload(
          file_path: file.path,
          org: "acme",
          repo: "web",
          pr_number: 42,
          commit_sha: "abc1234",
          route_name: "dashboard"
        )
      }.to raise_error(Screenshots::Storage::StorageError, /S3 upload failed/)
    ensure
      file.close
      file.unlink
    end

    it "returns a presigned URL for the uploaded object" do
      file = Tempfile.new([ "screenshot", ".png" ])
      file.write("fake png data")
      file.rewind

      s3_client.stub_responses(:put_object, {})
      allow(storage).to receive(:signed_url).and_return("https://example.test/uploaded.png?X-Amz-Signature=123")

      url = storage.upload(
        file_path: file.path,
        org: "acme",
        repo: "web",
        pr_number: 42,
        commit_sha: "abc1234",
        route_name: "dashboard"
      )

      expect(url).to include("X-Amz-Signature")
    ensure
      file.close
      file.unlink
    end
  end

  describe "#signed_url" do
    it "delegates to the shared artifact storage with the configured URL TTL" do
      presigner = instance_double(Aws::S3::Presigner)
      storage = described_class.new(bucket: "test-bucket", region: "us-east-1", url_ttl: 1234)

      allow(storage.artifact_storage).to receive_messages(client: s3_client, presigner: presigner)
      allow(presigner).to receive(:presigned_url).and_return("https://example.test/screenshot.png")

      storage.signed_url("screenshots/acme/web/pr-42/abc1234/dashboard.png")

      expect(presigner).to have_received(:presigned_url).with(
        :get_object,
        bucket: "test-bucket",
        key: "screenshots/acme/web/pr-42/abc1234/dashboard.png",
        expires_in: 1234
      )
    end
  end

  describe "#upload_trace" do
    it "uploads a trace archive and returns a presigned URL" do
      allow(storage).to receive(:put_object)
      allow(storage).to receive(:signed_url).and_return("https://example.test/trace.zip?X-Amz-Signature=abc")

      trace_tempfile do |file|
        expect(
          storage.upload_trace(file_path: file.path, org: "acme", repo: "web", pr_number: 42, commit_sha: "abc1234")
        ).to eq("https://example.test/trace.zip?X-Amz-Signature=abc")

        expect(storage).to have_received(:put_object).with(
          file_path: file.path,
          key: "screenshots/acme/web/pr-42/abc1234/trace.zip",
          content_type: "application/zip"
        )
      end
    end
  end

  describe "#upload_video" do
    it "uploads a session video and returns a presigned URL" do
      allow(storage).to receive(:put_object)
      allow(storage).to receive(:signed_url).and_return("https://example.test/capture.webm?X-Amz-Signature=xyz")

      video_tempfile do |file|
        expect(
          storage.upload_video(file_path: file.path, org: "acme", repo: "web", pr_number: 42, commit_sha: "abc1234")
        ).to eq("https://example.test/capture.webm?X-Amz-Signature=xyz")

        expect(storage).to have_received(:put_object).with(
          file_path: file.path,
          key: "screenshots/acme/web/pr-42/abc1234/capture.webm",
          content_type: "video/webm"
        )
      end
    end
  end

  describe "#previous_screenshots" do
    it "returns signed URLs for the most recent previous commit" do
      s3_client.stub_responses(:list_objects_v2, {
        contents: [
          { key: "screenshots/acme/web/pr-42/old111/dashboard.png", last_modified: 2.hours.ago },
          { key: "screenshots/acme/web/pr-42/old111/homepage.png", last_modified: 2.hours.ago },
          { key: "screenshots/acme/web/pr-42/current/dashboard.png", last_modified: 1.minute.ago },
          { key: "screenshots/acme/web/pr-42/current/homepage.png", last_modified: 1.minute.ago }
        ],
        is_truncated: false
      })
      allow(storage).to receive(:signed_url) do |key|
        "https://example.test/#{File.basename(key)}?X-Amz-Signature=123"
      end

      result = storage.previous_screenshots(org: "acme", repo: "web", pr_number: 42, exclude_sha: "current")

      expect(result.keys).to contain_exactly("dashboard", "homepage")
      expect(result["dashboard"]).to eq("https://example.test/dashboard.png?X-Amz-Signature=123")
    end

    it "picks the most recent commit when multiple previous commits exist" do
      s3_client.stub_responses(:list_objects_v2, {
        contents: [
          { key: "screenshots/acme/web/pr-42/older/dashboard.png", last_modified: 1.day.ago },
          { key: "screenshots/acme/web/pr-42/newer/dashboard.png", last_modified: 2.hours.ago },
          { key: "screenshots/acme/web/pr-42/current/dashboard.png", last_modified: 1.minute.ago }
        ],
        is_truncated: false
      })
      allow(storage).to receive(:signed_url) do |key|
        "https://example.test/#{File.basename(key)}?X-Amz-Signature=123"
      end

      result = storage.previous_screenshots(org: "acme", repo: "web", pr_number: 42, exclude_sha: "current")

      expect(result["dashboard"]).to eq("https://example.test/dashboard.png?X-Amz-Signature=123")
    end

    it "excludes non-PNG artifacts such as trace and video files" do
      s3_client.stub_responses(:list_objects_v2, {
        contents: [
          { key: "screenshots/acme/web/pr-42/old/dashboard.png", last_modified: 1.hour.ago },
          { key: "screenshots/acme/web/pr-42/old/trace.zip", last_modified: 1.hour.ago },
          { key: "screenshots/acme/web/pr-42/old/capture.webm", last_modified: 1.hour.ago },
          { key: "screenshots/acme/web/pr-42/current/dashboard.png", last_modified: 1.minute.ago }
        ],
        is_truncated: false
      })
      allow(storage).to receive(:signed_url) do |key|
        "https://example.test/#{File.basename(key)}?X-Amz-Signature=123"
      end

      result = storage.previous_screenshots(org: "acme", repo: "web", pr_number: 42, exclude_sha: "current")

      expect(result.keys).to contain_exactly("dashboard")
    end

    it "returns empty hash when no previous commits exist" do
      s3_client.stub_responses(:list_objects_v2, {
        contents: [
          { key: "screenshots/acme/web/pr-42/current/dashboard.png", last_modified: 1.minute.ago }
        ],
        is_truncated: false
      })

      result = storage.previous_screenshots(org: "acme", repo: "web", pr_number: 42, exclude_sha: "current")

      expect(result).to eq({})
    end

    it "ignores non-PNG artifacts when finding the previous screenshot set" do
      s3_client.stub_responses(:list_objects_v2, {
        contents: [
          { key: "screenshots/acme/web/pr-42/old/dashboard.png", last_modified: 1.hour.ago },
          { key: "screenshots/acme/web/pr-42/old/trace.zip", last_modified: 1.hour.ago },
          { key: "screenshots/acme/web/pr-42/old/capture.webm", last_modified: 1.hour.ago },
          { key: "screenshots/acme/web/pr-42/current/dashboard.png", last_modified: 1.minute.ago }
        ],
        is_truncated: false
      })
      allow(storage).to receive(:signed_url) { |key| "https://example.test/#{File.basename(key)}" }

      expect(storage.previous_screenshots(org: "acme", repo: "web", pr_number: 42, exclude_sha: "current"))
        .to eq({ "dashboard" => "https://example.test/dashboard.png" })
    end

    it "returns empty hash on S3 errors" do
      s3_client.stub_responses(:list_objects_v2, "ServiceError")

      result = storage.previous_screenshots(org: "acme", repo: "web", pr_number: 42, exclude_sha: "current")

      expect(result).to eq({})
    end
  end

  describe "#delete_pr_screenshots" do
    it "deletes all objects under the PR prefix" do
      s3_client.stub_responses(:list_objects_v2, {
        contents: [
          { key: "screenshots/acme/web/pr-42/abc/dashboard.png", last_modified: 1.day.ago },
          { key: "screenshots/acme/web/pr-42/abc/homepage.png", last_modified: 1.day.ago }
        ],
        is_truncated: false
      })
      s3_client.stub_responses(:delete_objects, {})

      expect { storage.delete_pr_screenshots(org: "acme", repo: "web", pr_number: 42) }
        .not_to raise_error
    end
  end

  describe "#cleanup_old_screenshots" do
    it "deletes objects older than retention period" do
      s3_client.stub_responses(:list_objects_v2, {
        contents: [
          { key: "screenshots/acme/web/pr-1/old/dash.png", last_modified: 60.days.ago },
          { key: "screenshots/acme/web/pr-2/new/dash.png", last_modified: 1.day.ago }
        ],
        is_truncated: false
      })
      s3_client.stub_responses(:delete_objects, {})

      deleted = storage.cleanup_old_screenshots(retention_days: 30)

      expect(deleted).to eq(1)
    end

    it "returns zero when no old objects exist" do
      s3_client.stub_responses(:list_objects_v2, {
        contents: [
          { key: "screenshots/acme/web/pr-2/new/dash.png", last_modified: 1.day.ago }
        ],
        is_truncated: false
      })

      deleted = storage.cleanup_old_screenshots(retention_days: 30)

      expect(deleted).to eq(0)
    end
  end

  describe "#configured?" do
    it "mirrors the shared artifact storage configuration check" do
      expect(storage.configured?).to eq(storage.artifact_storage.configured?)
    end
  end

  describe ".configured?" do
    around do |example|
      original_env = ENV.to_h.slice(
        "SCREENSHOTS_S3_ACCESS_KEY_ID",
        "SCREENSHOTS_S3_SECRET_ACCESS_KEY",
        "SCREENSHOTS_S3_URL_TTL"
      )
      example.run
    ensure
      %w[SCREENSHOTS_S3_ACCESS_KEY_ID SCREENSHOTS_S3_SECRET_ACCESS_KEY SCREENSHOTS_S3_URL_TTL].each do |key|
        original_env.key?(key) ? ENV[key] = original_env[key] : ENV.delete(key)
      end
    end

    it "checks only credentials and ignores unrelated URL TTL settings" do
      ENV["SCREENSHOTS_S3_ACCESS_KEY_ID"] = "AKIA..."
      ENV["SCREENSHOTS_S3_SECRET_ACCESS_KEY"] = "secret"
      ENV["SCREENSHOTS_S3_URL_TTL"] = (described_class::MAX_URL_TTL + 1).to_s

      expect(described_class.configured?).to be(true)
    end
  end

  describe "default URL TTL configuration" do
    it "delegates TTL resolution to the shared artifact storage" do
      expect(described_class::MAX_URL_TTL).to eq(ArtifactStorage::MAX_URL_TTL)
      expect(described_class::DEFAULT_URL_TTL).to eq(ArtifactStorage::DEFAULT_URL_TTL)
    end
  end

  describe "#artifact_key" do
    it "builds the correct S3 key path for a GIF artifact" do
      key = storage.artifact_key(
        org: "acme",
        repo: "web",
        pr_number: 42,
        commit_sha: "abc1234",
        route_name: "dashboard",
        extension: ".gif"
      )

      expect(key).to eq("screenshots/acme/web/pr-42/abc1234/dashboard.gif")
    end

    it "builds the correct S3 key path for a WebM artifact" do
      key = storage.artifact_key(
        org: "acme",
        repo: "web",
        pr_number: 42,
        commit_sha: "abc1234",
        route_name: "dashboard",
        extension: ".webm"
      )

      expect(key).to eq("screenshots/acme/web/pr-42/abc1234/dashboard.webm")
    end
  end

  describe "#upload_artifact" do
    let(:gif_file) do
      Tempfile.new([ "trace", ".gif" ]).tap do |f|
        f.write("GIF89a-fake-data")
        f.rewind
      end
    end

    let(:webm_file) do
      Tempfile.new([ "trace", ".webm" ]).tap do |f|
        f.write("fake webm data")
        f.rewind
      end
    end

    before do
      s3_client.stub_responses(:put_object, {})
    end

    after do
      gif_file.close
      gif_file.unlink
      webm_file.close
      webm_file.unlink
    end

    it "uploads a GIF file with the correct content type and returns a presigned URL" do
      allow(storage).to receive(:signed_url).and_return("https://example.test/dashboard.gif?X-Amz-Signature=123")

      url = storage.upload_artifact(
        file_path: gif_file.path,
        org: "acme",
        repo: "web",
        pr_number: 42,
        commit_sha: "abc1234",
        route_name: "dashboard"
      )

      expect(url).to eq("https://example.test/dashboard.gif?X-Amz-Signature=123")
      expect(s3_client.api_requests.last[:params][:content_type]).to eq("image/gif")
    end

    it "uploads a WebM file with the correct content type" do
      allow(storage).to receive(:signed_url).and_return("https://example.test/dashboard.webm?X-Amz-Signature=123")

      url = storage.upload_artifact(
        file_path: webm_file.path,
        org: "acme",
        repo: "web",
        pr_number: 42,
        commit_sha: "abc1234",
        route_name: "dashboard"
      )

      expect(url).to eq("https://example.test/dashboard.webm?X-Amz-Signature=123")
      expect(s3_client.api_requests.last[:params][:content_type]).to eq("video/webm")
    end

    it "raises StorageError when the file extension is unsupported" do
      unknown_file = Tempfile.new([ "trace", ".tiff" ]).tap { |f| f.write("fake tiff"); f.rewind }

      expect {
        storage.upload_artifact(
          file_path: unknown_file.path,
          org: "acme",
          repo: "web",
          pr_number: 42,
          commit_sha: "abc1234",
          route_name: "dashboard"
        )
      }.to raise_error(Screenshots::Storage::StorageError, /unsupported artifact extension/)
    ensure
      unknown_file&.close
      unknown_file&.unlink
    end

    it "honors an explicit extension override when storing the artifact" do
      allow(storage).to receive(:signed_url).and_return("https://example.test/dashboard.gif?X-Amz-Signature=123")

      storage.upload_artifact(
        file_path: webm_file.path,
        org: "acme",
        repo: "web",
        pr_number: 42,
        commit_sha: "abc1234",
        route_name: "dashboard",
        extension: ".gif"
      )

      expect(s3_client.api_requests.last[:params][:key]).to eq("screenshots/acme/web/pr-42/abc1234/dashboard.gif")
    end

    it "raises StorageError on S3 failure" do
      s3_client.stub_responses(:put_object, "ServiceError")

      expect {
        storage.upload_artifact(
          file_path: gif_file.path,
          org: "acme",
          repo: "web",
          pr_number: 42,
          commit_sha: "abc1234",
          route_name: "dashboard"
        )
      }.to raise_error(Screenshots::Storage::StorageError, /S3 upload failed/)
    end
  end

  describe "#previous_artifacts" do
    it "groups artifacts by route and format symbol for the latest previous commit" do
      s3_client.stub_responses(:list_objects_v2, {
        contents: [
          { key: "screenshots/acme/web/pr-42/old111/dashboard.png", last_modified: 2.hours.ago },
          { key: "screenshots/acme/web/pr-42/old111/dashboard.gif", last_modified: 2.hours.ago },
          { key: "screenshots/acme/web/pr-42/old111/dashboard.webm", last_modified: 2.hours.ago },
          { key: "screenshots/acme/web/pr-42/current/dashboard.png", last_modified: 1.minute.ago }
        ],
        is_truncated: false
      })
      allow(storage).to receive(:signed_url) do |key|
        "https://example.test/#{File.basename(key)}?X-Amz-Signature=123"
      end

      result = storage.previous_artifacts(org: "acme", repo: "web", pr_number: 42, exclude_sha: "current")

      expect(result.keys).to contain_exactly("dashboard")
      expect(result["dashboard"].keys).to contain_exactly(:png, :gif, :webm)
      expect(result["dashboard"][:gif]).to eq("https://example.test/dashboard.gif?X-Amz-Signature=123")
    end

    it "returns an empty hash when no previous commits exist" do
      s3_client.stub_responses(:list_objects_v2, {
        contents: [
          { key: "screenshots/acme/web/pr-42/current/dashboard.png", last_modified: 1.minute.ago }
        ],
        is_truncated: false
      })

      result = storage.previous_artifacts(org: "acme", repo: "web", pr_number: 42, exclude_sha: "current")

      expect(result).to eq({})
    end

    it "returns an empty hash on S3 errors" do
      s3_client.stub_responses(:list_objects_v2, "ServiceError")

      result = storage.previous_artifacts(org: "acme", repo: "web", pr_number: 42, exclude_sha: "current")

      expect(result).to eq({})
    end

    it "honors the extensions filter" do
      s3_client.stub_responses(:list_objects_v2, {
        contents: [
          { key: "screenshots/acme/web/pr-42/old/dashboard.png", last_modified: 2.hours.ago },
          { key: "screenshots/acme/web/pr-42/old/dashboard.gif", last_modified: 2.hours.ago }
        ],
        is_truncated: false
      })
      allow(storage).to receive(:signed_url) do |key|
        "https://example.test/#{File.basename(key)}?X-Amz-Signature=123"
      end

      result = storage.previous_artifacts(
        org: "acme",
        repo: "web",
        pr_number: 42,
        exclude_sha: "current",
        extensions: [ ".gif" ]
      )

      expect(result["dashboard"].keys).to contain_exactly(:gif)
    end
  end
end
