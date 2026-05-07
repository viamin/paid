# frozen_string_literal: true

require "rails_helper"
require "aws-sdk-s3"

RSpec.describe Screenshots::Storage do
  let(:s3_client) { Aws::S3::Client.new(stub_responses: true) }
  let(:storage) { described_class.new(bucket: "test-bucket", region: "us-east-1") }

  before do
    allow(storage).to receive_messages(
      s3_client: s3_client,
      presigner: Aws::S3::Presigner.new(client: s3_client)
    )
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

  describe "#upload" do
    it "uploads a file to S3 and returns a public URL" do
      file = Tempfile.new([ "screenshot", ".png" ])
      file.write("fake png data")
      file.rewind

      s3_client.stub_responses(:put_object, {})

      url = storage.upload(
        file_path: file.path,
        org: "acme",
        repo: "web",
        pr_number: 42,
        commit_sha: "abc1234",
        route_name: "dashboard"
      )

      expect(url).to eq("https://test-bucket.s3.us-east-1.amazonaws.com/screenshots/acme/web/pr-42/abc1234/dashboard.png")
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

    it "returns a public URL (not a presigned URL) for the uploaded object" do
      file = Tempfile.new([ "screenshot", ".png" ])
      file.write("fake png data")
      file.rewind

      s3_client.stub_responses(:put_object, {})

      url = storage.upload(
        file_path: file.path,
        org: "acme",
        repo: "web",
        pr_number: 42,
        commit_sha: "abc1234",
        route_name: "dashboard"
      )

      expect(url).not_to include("X-Amz-Signature")
      expect(url).to eq("https://test-bucket.s3.us-east-1.amazonaws.com/screenshots/acme/web/pr-42/abc1234/dashboard.png")
    ensure
      file.close
      file.unlink
    end
  end

  describe "#signed_url" do
    it "uses the configured URL TTL" do
      presigner = instance_double(Aws::S3::Presigner)
      storage = described_class.new(bucket: "test-bucket", region: "us-east-1", url_ttl: 1234)

      allow(storage).to receive(:presigner).and_return(presigner)
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

  describe "#public_url" do
    it "builds a stable S3 URL when no custom endpoint is configured" do
      url = storage.send(:public_url, "screenshots/acme/web/pr-42/abc1234/dashboard.png")

      expect(url).to eq("https://test-bucket.s3.us-east-1.amazonaws.com/screenshots/acme/web/pr-42/abc1234/dashboard.png")
    end

    it "builds a stable endpoint URL when a custom endpoint is configured" do
      allow(storage).to receive(:endpoint).and_return("https://s3.example.test")

      url = storage.send(:public_url, "screenshots/acme/web/pr-42/abc1234/dashboard.png")

      expect(url).to eq("https://s3.example.test/test-bucket/screenshots/acme/web/pr-42/abc1234/dashboard.png")
    end

    it "URL-encodes path segments" do
      url = storage.send(:public_url, "screenshots/acme/web/pr-42/abc1234/project show.png")

      expect(url).to end_with("/screenshots/acme/web/pr-42/abc1234/project%20show.png")
    end
  end

  describe "#previous_screenshots" do
    it "returns public URLs for the most recent previous commit" do
      s3_client.stub_responses(:list_objects_v2, {
        contents: [
          { key: "screenshots/acme/web/pr-42/old111/dashboard.png", last_modified: 2.hours.ago },
          { key: "screenshots/acme/web/pr-42/old111/homepage.png", last_modified: 2.hours.ago },
          { key: "screenshots/acme/web/pr-42/current/dashboard.png", last_modified: 1.minute.ago },
          { key: "screenshots/acme/web/pr-42/current/homepage.png", last_modified: 1.minute.ago }
        ],
        is_truncated: false
      })

      result = storage.previous_screenshots(org: "acme", repo: "web", pr_number: 42, exclude_sha: "current")

      expect(result.keys).to contain_exactly("dashboard", "homepage")
      expect(result["dashboard"]).to eq("https://test-bucket.s3.us-east-1.amazonaws.com/screenshots/acme/web/pr-42/old111/dashboard.png")
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

      result = storage.previous_screenshots(org: "acme", repo: "web", pr_number: 42, exclude_sha: "current")

      expect(result["dashboard"]).to eq("https://test-bucket.s3.us-east-1.amazonaws.com/screenshots/acme/web/pr-42/newer/dashboard.png")
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
    it "returns true when credentials are present" do
      allow(storage).to receive_messages(access_key_id: "AKIA...", secret_access_key: "secret")

      expect(storage.configured?).to be true
    end

    it "returns false when credentials are missing" do
      allow(storage).to receive_messages(access_key_id: nil, secret_access_key: nil)

      expect(storage.configured?).to be false
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
    around do |example|
      original_env = ENV.to_h.slice("SCREENSHOTS_S3_URL_TTL")
      ENV.delete("SCREENSHOTS_S3_URL_TTL")
      example.run
    ensure
      if original_env.key?("SCREENSHOTS_S3_URL_TTL")
        ENV["SCREENSHOTS_S3_URL_TTL"] = original_env["SCREENSHOTS_S3_URL_TTL"]
      else
        ENV.delete("SCREENSHOTS_S3_URL_TTL")
      end
    end

    it "defaults to the S3 presigner maximum" do
      storage = described_class.new(bucket: "test-bucket", region: "us-east-1")

      expect(storage.send(:configured_url_ttl)).to eq(described_class::MAX_URL_TTL)
    end

    it "uses the SCREENSHOTS_S3_URL_TTL override when present" do
      ENV["SCREENSHOTS_S3_URL_TTL"] = "7200"

      storage = described_class.new(bucket: "test-bucket", region: "us-east-1")

      expect(storage.send(:configured_url_ttl)).to eq(7200)
    end

    it "rejects non-positive TTL overrides" do
      ENV["SCREENSHOTS_S3_URL_TTL"] = "0"

      storage = described_class.new(bucket: "test-bucket", region: "us-east-1")

      expect { storage.send(:configured_url_ttl) }
        .to raise_error(ArgumentError, /SCREENSHOTS_S3_URL_TTL must be positive/)
    end

    it "rejects TTL overrides above the S3 presigner maximum" do
      ENV["SCREENSHOTS_S3_URL_TTL"] = (described_class::MAX_URL_TTL + 1).to_s

      storage = described_class.new(bucket: "test-bucket", region: "us-east-1")

      expect { storage.send(:configured_url_ttl) }
        .to raise_error(ArgumentError, /cannot exceed #{described_class::MAX_URL_TTL} seconds/)
    end
  end
end
