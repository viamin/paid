# frozen_string_literal: true

require "rails_helper"
require "aws-sdk-s3"

# @spec ARTIFACT-STORAGE-001
# @spec ARTIFACT-STORAGE-002
# @spec ARTIFACT-STORAGE-004
RSpec.describe ArtifactStorage, :no_db do
  let(:s3_client) { Aws::S3::Client.new(stub_responses: true) }
  let(:store) { described_class.new(bucket: "test-bucket", region: "us-east-1") }

  before do
    allow(store).to receive_messages(
      client: s3_client,
      presigner: Aws::S3::Presigner.new(client: s3_client)
    )
  end

  around do |example|
    env_keys = %w[
      SCREENSHOTS_S3_BUCKET
      SCREENSHOTS_S3_REGION
      SCREENSHOTS_S3_ACCESS_KEY_ID
      SCREENSHOTS_S3_SECRET_ACCESS_KEY
      SCREENSHOTS_S3_URL_TTL
      SCREENSHOTS_S3_ENDPOINT
    ]
    original_env = ENV.to_h.slice(*env_keys)
    env_keys.each { |key| ENV.delete(key) }
    example.run
  ensure
    env_keys.each do |key|
      original_env.key?(key) ? ENV[key] = original_env[key] : ENV.delete(key)
    end
  end

  describe "#client" do
    it "returns a memoized S3 client" do
      client = store.client

      expect(client).to be_an(Aws::S3::Client)
      expect(store.client).to be(client)
    end
  end

  it "aliases s3_client to client for backward compatibility" do
    expect(store.s3_client).to be(store.client)
  end

  describe "#bucket and #region" do
    it "uses the constructor overrides" do
      store = described_class.new(bucket: "my-bucket", region: "eu-west-1")

      expect(store.bucket).to eq("my-bucket")
      expect(store.region).to eq("eu-west-1")
    end

    it "falls back to configured defaults" do
      ENV["SCREENSHOTS_S3_BUCKET"] = "env-bucket"
      ENV["SCREENSHOTS_S3_REGION"] = "ap-southeast-2"

      store = described_class.new

      expect(store.bucket).to eq("env-bucket")
      expect(store.region).to eq("ap-southeast-2")
    end

    it "falls back to the built-in defaults when nothing is configured" do
      store = described_class.new

      expect(store.bucket).to eq(described_class::DEFAULT_BUCKET)
      expect(store.region).to eq(described_class::DEFAULT_REGION)
    end
  end

  describe "#upload" do
    it "uploads a file and returns a presigned URL" do
      file = Tempfile.new([ "report", ".pdf" ])
      file.write("fake pdf data")
      file.rewind
      s3_client.stub_responses(:put_object, {})
      allow(store).to receive(:signed_url).and_return("https://example.test/reports/acme/pr-42/r.pdf?X-Amz-Signature=1")

      url = store.upload(file_path: file.path, key: "reports/acme/pr-42/r.pdf")

      expect(url).to eq("https://example.test/reports/acme/pr-42/r.pdf?X-Amz-Signature=1")
      expect(s3_client.api_requests.last[:params][:bucket]).to eq("test-bucket")
      expect(s3_client.api_requests.last[:params][:key]).to eq("reports/acme/pr-42/r.pdf")
    ensure
      file.close
      file.unlink
    end

    it "infers the content type from the file when omitted" do
      file = Tempfile.new([ "capture", ".png" ])
      file.write("fake png")
      file.rewind
      s3_client.stub_responses(:put_object, {})
      allow(store).to receive(:signed_url).and_return("https://example.test/x.png")

      store.upload(file_path: file.path, key: "artifacts/x.png")

      expect(s3_client.api_requests.last[:params][:content_type]).to eq("image/png")
    ensure
      file.close
      file.unlink
    end

    it "honors an explicit content type override" do
      file = Tempfile.new([ "data", ".bin" ])
      file.write("bytes")
      file.rewind
      s3_client.stub_responses(:put_object, {})
      allow(store).to receive(:signed_url).and_return("https://example.test/data.bin")

      store.upload(file_path: file.path, key: "artifacts/data.bin", content_type: "application/x-paid")

      expect(s3_client.api_requests.last[:params][:content_type]).to eq("application/x-paid")
    ensure
      file.close
      file.unlink
    end

    it "raises StorageError on S3 failure" do
      file = Tempfile.new([ "report", ".pdf" ])
      file.write("fake pdf data")
      file.rewind
      s3_client.stub_responses(:put_object, "ServiceError")

      expect {
        store.upload(file_path: file.path, key: "reports/acme/pr-42/r.pdf")
      }.to raise_error(ArtifactStorage::StorageError, /S3 upload failed/)
    ensure
      file.close
      file.unlink
    end
  end

  describe "#signed_url" do
    it "builds a presigned GET URL using the configured TTL" do
      presigner = instance_double(Aws::S3::Presigner)
      store = described_class.new(bucket: "test-bucket", region: "us-east-1", url_ttl: 7200)

      allow(store).to receive(:presigner).and_return(presigner)
      allow(presigner).to receive(:presigned_url).and_return("https://example.test/key?X-Amz-Signature=z")

      store.signed_url("reports/acme/pr-42/r.pdf")

      expect(presigner).to have_received(:presigned_url).with(
        :get_object,
        bucket: "test-bucket",
        key: "reports/acme/pr-42/r.pdf",
        expires_in: 7200
      )
    end
  end

  describe "#delete" do
    it "deletes the object" do
      s3_client.stub_responses(:delete_object, {})

      expect { store.delete("reports/acme/pr-42/r.pdf") }.not_to raise_error
      expect(s3_client.api_requests.last[:operation_name]).to eq(:delete_object)
      expect(s3_client.api_requests.last[:params][:key]).to eq("reports/acme/pr-42/r.pdf")
    end

    it "raises StorageError on S3 failure" do
      s3_client.stub_responses(:delete_object, "ServiceError")

      expect { store.delete("reports/acme/pr-42/r.pdf") }
        .to raise_error(ArtifactStorage::StorageError, /S3 delete failed/)
    end
  end

  describe "#delete_prefix" do
    it "deletes every object under the prefix and returns the count" do
      s3_client.stub_responses(:list_objects_v2, {
        contents: [
          { key: "reports/acme/pr-42/a.pdf", last_modified: 1.day.ago },
          { key: "reports/acme/pr-42/b.pdf", last_modified: 1.day.ago }
        ],
        is_truncated: false
      })
      s3_client.stub_responses(:delete_objects, {})

      deleted = store.delete_prefix("reports/acme/pr-42/")

      expect(deleted).to eq(2)
      expect(s3_client.api_requests.last[:operation_name]).to eq(:delete_objects)
    end

    it "returns zero when nothing is under the prefix" do
      s3_client.stub_responses(:list_objects_v2, { contents: [], is_truncated: false })

      expect(store.delete_prefix("reports/empty/")).to eq(0)
    end
  end

  describe "#configured?" do
    it "returns true when credentials are present in the environment" do
      ENV["SCREENSHOTS_S3_ACCESS_KEY_ID"] = "AKIA..."
      ENV["SCREENSHOTS_S3_SECRET_ACCESS_KEY"] = "secret"

      expect(store.configured?).to be true
    end

    it "returns false when credentials are missing" do
      expect(store.configured?).to be false
    end
  end

  describe ".configured?" do
    it "mirrors the instance check using the same credential resolution" do
      ENV["SCREENSHOTS_S3_ACCESS_KEY_ID"] = "AKIA..."
      ENV["SCREENSHOTS_S3_SECRET_ACCESS_KEY"] = "secret"

      expect(described_class.configured?).to be(true)
      expect(described_class.configured?).to eq(store.configured?)
    end

    it "returns false without credentials" do
      expect(described_class.configured?).to be false
    end
  end

  describe ".configured_url_ttl" do
    it "defaults to the S3 presigner maximum" do
      expect(described_class.configured_url_ttl).to eq(described_class::MAX_URL_TTL)
    end

    it "uses the SCREENSHOTS_S3_URL_TTL override when present" do
      ENV["SCREENSHOTS_S3_URL_TTL"] = "7200"

      expect(described_class.configured_url_ttl).to eq(7200)
    end

    it "rejects non-positive TTL overrides" do
      ENV["SCREENSHOTS_S3_URL_TTL"] = "0"

      expect { described_class.configured_url_ttl }
        .to raise_error(ArgumentError, /SCREENSHOTS_S3_URL_TTL must be positive/)
    end

    it "rejects TTL overrides above the S3 presigner maximum" do
      ENV["SCREENSHOTS_S3_URL_TTL"] = (described_class::MAX_URL_TTL + 1).to_s

      expect { described_class.configured_url_ttl }
        .to raise_error(ArgumentError, /cannot exceed #{described_class::MAX_URL_TTL} seconds/)
    end
  end
end
