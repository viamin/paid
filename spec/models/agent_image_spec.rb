# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentImage, type: :model do # @spec CONTAINER-RUNTIME-019
  describe "associations" do
    it { is_expected.to belong_to(:account) }
  end

  describe "validations" do
    subject { build(:agent_image) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:tag) }
    it { is_expected.to validate_presence_of(:digest) }
    it { is_expected.to validate_presence_of(:repository) }
    it { is_expected.to validate_presence_of(:built_at) }
    it { is_expected.to validate_inclusion_of(:status).in_array(%w[active deprecated blocked]) }
    it { is_expected.to validate_inclusion_of(:architecture).in_array(%w[amd64 arm64 386 arm ppc64le s390x]) }

    it "defaults the registry to docker.io when blank" do
      image = build(:agent_image, registry: nil)
      expect(image).to be_valid
      expect(image.registry).to eq("docker.io")
    end

    it "defaults the architecture to amd64 when blank" do
      image = build(:agent_image, architecture: nil)
      expect(image).to be_valid
      expect(image.architecture).to eq("amd64")
    end
  end

  describe "digest format" do # @spec CONTAINER-RUNTIME-019
    it "accepts a sha256 digest in canonical sha256:<hex> form" do
      image = build(:agent_image, digest: "sha256:" + "a" * 64)
      expect(image).to be_valid
    end

    it "accepts a bare 64-character hex sha256 digest and canonicalizes the prefix" do
      image = build(:agent_image, digest: "b" * 64)
      expect(image).to be_valid
      expect(image.digest).to eq("sha256:" + "b" * 64)
    end

    it "emits a valid OCI digest reference for bare hex input" do
      image = build(:agent_image, repository: "paid-agent", digest: "b" * 64)
      image.valid?
      expect(image.digest_reference).to eq("paid-agent@sha256:" + "b" * 64)
    end

    it "rejects a digest that is not a sha256 hash" do
      image = build(:agent_image, digest: "not-a-digest")
      expect(image).not_to be_valid
      expect(image.errors[:digest]).to be_present
    end

    it "rejects a sha256 digest with the wrong length" do
      image = build(:agent_image, digest: "sha256:" + "c" * 63)
      expect(image).not_to be_valid
      expect(image.errors[:digest]).to be_present
    end
  end

  describe "registry and repository formatting" do
    it "lowercases the registry" do
      image = create(:agent_image, registry: "DOCKER.IO")
      expect(image.registry).to eq("docker.io")
    end

    it "lowercases the repository" do
      image = create(:agent_image, repository: "Paid-Agent")
      expect(image.repository).to eq("paid-agent")
    end

    it "treats blank registry as docker.io" do
      image = create(:agent_image, registry: nil)
      expect(image.registry).to eq("docker.io")
    end

    it "strips whitespace from the tag" do
      image = create(:agent_image, tag: "  latest  ")
      expect(image.tag).to eq("latest")
    end
  end

  describe "immutability" do # @spec CONTAINER-RUNTIME-020
    it "prevents digest changes after creation" do
      image = create(:agent_image, digest: "sha256:" + "a" * 64)
      image.digest = "sha256:" + "b" * 64
      expect(image).not_to be_valid
      expect(image.errors[:base]).to include("agent image identity fields are immutable after creation")
    end

    it "prevents architecture changes after creation" do
      image = create(:agent_image, architecture: "amd64")
      image.architecture = "arm64"
      expect(image).not_to be_valid
      expect(image.errors[:base]).to include("agent image identity fields are immutable after creation")
    end

    it "prevents registry changes after creation" do
      image = create(:agent_image, registry: "docker.io")
      image.registry = "ghcr.io"
      expect(image).not_to be_valid
      expect(image.errors[:base]).to include("agent image identity fields are immutable after creation")
    end

    it "prevents repository changes after creation" do
      image = create(:agent_image, repository: "paid-agent")
      image.repository = "paid-agent-other"
      expect(image).not_to be_valid
      expect(image.errors[:base]).to include("agent image identity fields are immutable after creation")
    end

    it "prevents tag changes after creation" do
      image = create(:agent_image, tag: "latest")
      image.tag = "previous"
      expect(image).not_to be_valid
      expect(image.errors[:base]).to include("agent image identity fields are immutable after creation")
    end

    it "prevents name changes after creation" do
      image = create(:agent_image, name: "base")
      image.name = "base-ruby"
      expect(image).not_to be_valid
      expect(image.errors[:base]).to include("agent image identity fields are immutable after creation")
    end

    it "allows provenance and metadata updates after creation" do
      image = create(:agent_image)
      image.provenance = { "git_sha" => "abc123" }
      image.metadata = { "build_log_url" => "https://example.test/builds/1" }
      expect(image).to be_valid
    end
  end

  describe "uniqueness" do # @spec CONTAINER-RUNTIME-021
    it "rejects a duplicate image identity within the same account" do
      identity = {
        account: create(:account),
        registry: "docker.io",
        repository: "paid-agent",
        digest: "sha256:" + "a" * 64,
        architecture: "amd64"
      }
      create(:agent_image, **identity)
      duplicate = build(:agent_image, **identity)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:digest]).to be_present
    end

    it "allows the same image identity across different accounts" do
      shared = {
        registry: "docker.io",
        repository: "paid-agent",
        digest: "sha256:" + "a" * 64,
        architecture: "amd64"
      }
      create(:agent_image, account: create(:account), **shared)
      other = build(:agent_image, account: create(:account), **shared)
      expect(other).to be_valid
    end

    it "rejects the bare hex form of a digest already registered in prefixed form" do
      identity = {
        account: create(:account),
        registry: "docker.io",
        repository: "paid-agent",
        architecture: "amd64"
      }
      create(:agent_image, digest: "sha256:" + "a" * 64, **identity)
      duplicate = build(:agent_image, digest: "a" * 64, **identity)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:digest]).to be_present
    end

    it "allows the same digest with a different architecture" do
      digest = "sha256:" + "a" * 64
      create(:agent_image, registry: "docker.io", repository: "paid-agent", digest: digest, architecture: "amd64")
      other = build(:agent_image, registry: "docker.io", repository: "paid-agent", digest: digest, architecture: "arm64")
      expect(other).to be_valid
    end
  end

  describe "change tracking" do # @spec CONTAINER-RUNTIME-021
    it "records a logidze history entry when mutable metadata changes" do
      image = create(:agent_image)
      image.update!(metadata: { "runbook_url" => "https://example.test/runbook" })
      expect(image.reload.log_data.versions.size).to be >= 2
    end
  end

  describe "status predicates" do
    it "is active by default" do
      image = create(:agent_image)
      expect(image).to be_active
      expect(image).not_to be_deprecated
      expect(image).not_to be_blocked
      expect(image).to be_schedulable
    end

    it "reports deprecated when status is deprecated" do
      image = create(:agent_image, :deprecated)
      expect(image).to be_deprecated
      expect(image).not_to be_active
      expect(image).not_to be_blocked
      expect(image).not_to be_schedulable
    end

    it "reports blocked when status is blocked" do
      image = create(:agent_image, :blocked)
      expect(image).to be_blocked
      expect(image).not_to be_active
      expect(image).not_to be_deprecated
      expect(image).not_to be_schedulable
    end
  end

  describe "deprecation" do # @spec CONTAINER-RUNTIME-022
    it "transitions active -> deprecated and stamps deprecated_at" do
      image = create(:agent_image)
      freeze_time = Time.current
      travel_to(freeze_time) do
        image.deprecate!(reason: "superseded by paid-agent:latest-amd64-2026.08.17")
      end
      expect(image).to be_deprecated
      expect(image.deprecated_at).to be_within(1.second).of(freeze_time)
      expect(image.deprecation_reason).to include("superseded")
    end

    it "is idempotent when called twice" do
      image = create(:agent_image)
      image.deprecate!(reason: "first")
      first_at = image.deprecated_at
      travel_to(1.hour.from_now) do
        image.deprecate!(reason: "second")
      end
      expect(image.deprecated_at).to eq(first_at)
    end

    it "rejects deprecating a blocked image" do
      image = create(:agent_image, :blocked)
      expect { image.deprecate!(reason: "irrelevant") }.to raise_error(ArgumentError)
    end

    it "rejects direct status updates without the deprecation audit fields" do
      image = create(:agent_image)

      expect { image.update!(status: "deprecated") }
        .to raise_error(ActiveRecord::RecordInvalid, /Deprecated at must be present/)
    end

    it "allows a direct status update when the deprecation audit fields are supplied" do
      image = create(:agent_image)
      freeze_time = Time.current

      travel_to(freeze_time) do
        image.update!(
          status: "deprecated",
          deprecated_at: freeze_time,
          deprecation_reason: "superseded by paid-agent:latest-amd64-2026.08.17"
        )
      end

      expect(image.reload).to be_deprecated
      expect(image.deprecated_at).to be_within(1.second).of(freeze_time)
    end
  end

  describe "blocking" do # @spec CONTAINER-RUNTIME-022
    it "transitions active -> blocked and stamps blocked_at" do
      image = create(:agent_image)
      freeze_time = Time.current
      travel_to(freeze_time) do
        image.block!(reason: "CVE-2026-9999 in base image")
      end
      expect(image).to be_blocked
      expect(image.blocked_at).to be_within(1.second).of(freeze_time)
      expect(image.blocked_reason).to include("CVE-2026-9999")
    end

    it "transitions deprecated -> blocked and preserves the deprecation timestamp" do
      image = create(:agent_image, :deprecated)
      original_deprecated_at = image.deprecated_at
      image.block!(reason: "discovered CVE late")
      expect(image).to be_blocked
      expect(image.deprecated_at).to eq(original_deprecated_at)
    end

    it "requires a reason when blocking" do
      image = create(:agent_image)
      expect { image.block!(reason: nil) }.to raise_error(ArgumentError)
      expect { image.block!(reason: "") }.to raise_error(ArgumentError)
    end

    it "rejects direct status updates without the blocking audit fields" do
      image = create(:agent_image)

      expect { image.update!(status: "blocked") }
        .to raise_error(ActiveRecord::RecordInvalid, /Blocked at must be present/)
    end

    it "rejects an illegal blocked -> deprecated status transition" do
      image = create(:agent_image, :blocked)

      expect do
        image.update!(
          status: "deprecated",
          deprecated_at: Time.current,
          deprecation_reason: "rollback"
        )
      end.to raise_error(ActiveRecord::RecordInvalid, /Status cannot transition from blocked to deprecated/)
    end
  end

  describe "scopes" do
    let!(:active) { create(:agent_image) }
    let!(:deprecated) { create(:agent_image, :deprecated) }
    let!(:blocked) { create(:agent_image, :blocked) }

    it ".active returns only active images" do
      expect(described_class.active).to contain_exactly(active)
    end

    it ".deprecated returns only deprecated images" do
      expect(described_class.deprecated).to contain_exactly(deprecated)
    end

    it ".blocked returns only blocked images" do
      expect(described_class.blocked).to contain_exactly(blocked)
    end

    it ".schedulable returns only active images" do
      expect(described_class.schedulable).to contain_exactly(active)
    end

    it ".historical returns non-active images for audit/rollback" do
      expect(described_class.historical).to contain_exactly(deprecated, blocked)
    end
  end

  describe "#reference" do
    it "omits docker.io from the reference because it is the implicit default" do
      image = build(:agent_image, registry: "docker.io", repository: "paid-agent", tag: "ruby")
      expect(image.reference).to eq("paid-agent:ruby")
    end

    it "includes a non-default registry in the reference" do
      image = build(:agent_image, registry: "ghcr.io", repository: "paid-agent", tag: "ruby")
      expect(image.reference).to eq("ghcr.io/paid-agent:ruby")
    end

    it "includes the digest when computing the digest-pinned reference" do
      digest = "sha256:" + "a" * 64
      image = build(:agent_image, registry: "docker.io", repository: "paid-agent", tag: "latest", digest: digest)
      expect(image.digest_reference).to eq("paid-agent@" + digest)
    end
  end
end
