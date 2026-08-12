# frozen_string_literal: true

require "rails_helper"
require "aws-sdk-s3"

# Verifies the stateless-host invariant: destroying or replacing a Rails (or
# Temporal worker) host must not destroy important Paid state. Durable state is
# either in PostgreSQL or in external object storage reached through
# ArtifactStorage — never on the host filesystem.
#
# @spec ARTIFACT-STORAGE-005
RSpec.describe "Stateless host durability invariant", :no_db, type: :model do
  describe "durable application state lives in PostgreSQL" do
    # These models hold the data that must survive a host replacement: run logs,
    # token usage/cost. They are DB-backed, not file-backed.
    [ AgentRunLog, TokenUsage ].each do |model|
      it "#{model.name} is an ActiveRecord model backed by a table" do
        expect(model.ancestors).to include(ActiveRecord::Base)
        expect(model.table_name).to be_present
      end
    end
  end

  describe "durable binary artifacts go to object storage, not local disk" do
    # ArtifactStorage is the single abstraction for durable binaries. Its
    # operations must talk to the S3-compatible client and never touch the host
    # filesystem (other than reading the local file being uploaded).
    let(:s3_client) { Aws::S3::Client.new(stub_responses: true) }
    let(:store) { ArtifactStorage.new(bucket: "durable-bucket", region: "us-east-1") }

    before do
      allow(store).to receive_messages(client: s3_client, presigner: Aws::S3::Presigner.new(client: s3_client))
    end

    it "uploads artifacts through the object-storage client" do
      file = Tempfile.new([ "artifact", ".png" ])
      file.write("payload")
      file.rewind
      s3_client.stub_responses(:put_object, {})
      allow(store).to receive(:signed_url).and_return("https://example.test/a.png?X-Amz-Signature=1")

      store.upload(file_path: file.path, key: "durable/artifacts/a.png")

      request = s3_client.api_requests.last
      expect(request[:operation_name]).to eq(:put_object)
      expect(request[:params][:bucket]).to eq("durable-bucket")
    ensure
      file.close
      file.unlink
    end

    it "deletes artifacts through the object-storage client" do
      s3_client.stub_responses(:delete_object, {})

      store.delete("durable/artifacts/a.png")

      expect(s3_client.api_requests.last[:operation_name]).to eq(:delete_object)
    end
  end

  describe "Screenshots::Storage reuses the shared object-storage client" do
    # Screenshots and traces are user-visible artifacts. They must reach object
    # storage via the shared ArtifactStorage client rather than constructing a
    # separate client or writing to local disk.
    it "delegates S3 client construction to ArtifactStorage" do
      shared_client = Aws::S3::Client.new(stub_responses: true)
      storage = Screenshots::Storage.new(bucket: "shared-bucket", region: "us-east-1")
      allow(storage.artifact_storage).to receive(:client).and_return(shared_client)

      expect(storage.artifact_storage).to be_an(ArtifactStorage)
      expect(storage.s3_client).to be(shared_client)
    end

    it "uploads a screenshot through the shared object-storage client" do
      s3_client = Aws::S3::Client.new(stub_responses: true)
      storage = Screenshots::Storage.new(bucket: "shared-bucket", region: "us-east-1")
      allow(storage.artifact_storage).to receive(:client).and_return(s3_client)
      allow(storage).to receive(:signed_url).and_return("https://example.test/dashboard.png?X-Amz-Signature=1")
      s3_client.stub_responses(:put_object, {})

      file = Tempfile.new([ "screenshot", ".png" ])
      file.write("png")
      file.rewind
      storage.upload(file_path: file.path, org: "acme", repo: "web", pr_number: 1, commit_sha: "sha", route_name: "dashboard")
      file.close
      file.unlink

      request = s3_client.api_requests.last
      expect(request[:operation_name]).to eq(:put_object)
      expect(request[:params][:bucket]).to eq("shared-bucket")
      expect(request[:params][:key]).to eq("screenshots/acme/web/pr-1/sha/dashboard.png")
    end
  end
end
