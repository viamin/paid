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
    it "uploads a file to S3 and returns a signed URL" do
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

      expect(url).to include("test-bucket")
      expect(url).to include("dashboard.png")
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
end
