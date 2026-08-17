# frozen_string_literal: true

# Immutable registry of agent container images. Each row represents a single
# (account, registry, repository, digest, architecture) identity that an agent
# run can be scheduled against. Identity fields are immutable after creation:
# a new image build produces a new digest, which is a new row. Status
# transitions drive scheduling and audit but the row is never deleted.
#
# Status states:
#
# - +active+ — schedulable; the image is available for new runs.
# - +deprecated+ — still runnable, but a successor has been recorded; not
#   selected for new placements, retained for rollback and historical audit.
# - +blocked+ — excluded from future scheduling (e.g. CVE), retained for audit
#   and to explain prior run outcomes.
#
# Status is the only mutating lifecycle surface. The state machine is
# +active -> deprecated -> blocked+; +active -> blocked+ is also allowed when
# a fresh image is blocked before any deprecation window. Transitions are
# idempotent so retrying an Avo action or job does not double-stamp timestamps.
#
# @spec CONTAINER-RUNTIME-019
# @spec CONTAINER-RUNTIME-020
# @spec CONTAINER-RUNTIME-021
# @spec CONTAINER-RUNTIME-022
# @see docs/rdrs/RDR-059-immutable-agent-runtime-images.md
# @see docs/intent/container-runtime/container-runtime-specs.md
class AgentImage < ApplicationRecord
  STATUSES = %w[active deprecated blocked].freeze
  ALLOWED_STATUS_TRANSITIONS = {
    "active" => %w[deprecated blocked],
    "deprecated" => %w[blocked],
    "blocked" => []
  }.freeze
  ARCHITECTURES = %w[amd64 arm64 386 arm ppc64le s390x].freeze
  SHA256_HEX_LENGTH = 64
  DEFAULT_REGISTRY = "docker.io"
  SHA256_PREFIX = "sha256:"
  DIGEST_FORMAT = /\A#{SHA256_PREFIX}[0-9a-f]{#{SHA256_HEX_LENGTH}}\z/

  # Identity fields. Once a row is persisted these are immutable: a different
  # digest, architecture, or repository is a different image, so the right
  # model answer is a new row, not an in-place edit.
  IMMUTABLE_ATTRIBUTES = %w[
    name
    tag
    registry
    repository
    digest
    architecture
    account_id
    built_at
  ].freeze

  belongs_to :account

  has_logidze

  validates :name, presence: true, length: { maximum: 100 }
  validates :tag, presence: true, length: { maximum: 255 }
  validates :registry, presence: true, length: { maximum: 255 }
  validates :repository, presence: true, length: { maximum: 255 }
  validates :digest, presence: true, format: { with: DIGEST_FORMAT, message: "must be a 64-character hex sha256 digest, optionally prefixed with 'sha256:'" }
  validates :architecture, presence: true, inclusion: { in: ARCHITECTURES }
  validates :status, inclusion: { in: STATUSES }
  validates :built_at, presence: true
  validate :identity_unique_within_account, on: :create
  validate :immutable_identity_after_creation, on: :update
  validate :status_transition_is_allowed, on: :update
  validate :status_audit_fields_present

  before_validation :normalize_fields

  scope :active, -> { where(status: "active") }
  scope :deprecated, -> { where(status: "deprecated") }
  scope :blocked, -> { where(status: "blocked") }
  scope :schedulable, -> { active }
  scope :historical, -> { where(status: %w[deprecated blocked]) }
  scope :for_profile, ->(name) { where(name: name) }
  scope :for_architecture, ->(arch) { where(architecture: arch) }

  def active?
    status == "active"
  end

  def deprecated?
    status == "deprecated"
  end

  def blocked?
    status == "blocked"
  end

  # True when the image is eligible to back new agent runs. Today this is the
  # same as +active?+ but the predicate is exposed so future state additions
  # (e.g. quarantined) do not have to be repeated at every call site.
  def schedulable?
    active?
  end

  # @return [String] the canonical +registry/repository:tag+ reference.
  #   +docker.io+ is omitted because Docker treats it as the implicit default;
  #   the rest keep the registry host so the reference is unambiguous.
  def reference
    base = "#{repository}:#{tag}"
    registry.blank? || registry == DEFAULT_REGISTRY ? base : "#{registry}/#{base}"
  end

  # @return [String] the digest-pinned +repository@digest+ reference used in
  #   production scheduling where the tag is allowed to drift upstream.
  def digest_reference
    "#{repository}@#{digest}"
  end

  # Transitions an active image to deprecated. Idempotent: calling it on an
  # already-deprecated image does not re-stamp +deprecated_at+ or replace the
  # recorded reason.
  def deprecate!(reason:)
    raise ArgumentError, "cannot deprecate a blocked image" if blocked?

    return self if deprecated?

    assign_attributes(
      status: "deprecated",
      deprecated_at: Time.current,
      deprecation_reason: reason.to_s.presence
    )
    save!
    self
  end

  # Transitions the image to blocked. Idempotent and additive: an
  # already-deprecated image can be blocked and keeps its original
  # +deprecated_at+ so the audit trail is complete.
  def block!(reason:)
    reason_text = reason.to_s.strip
    raise ArgumentError, "block reason is required" if reason_text.blank?
    return self if blocked?

    assign_attributes(
      status: "blocked",
      blocked_at: Time.current,
      blocked_reason: reason_text
    )
    save!
    self
  end

  private

  def normalize_fields
    self.name = name.to_s.strip
    self.tag = tag.to_s.strip
    self.registry = (registry.to_s.strip.presence || DEFAULT_REGISTRY).downcase
    self.repository = repository.to_s.strip.downcase
    self.digest = canonical_digest(digest)
    self.architecture = (architecture.to_s.strip.presence || "amd64").downcase
  end

  # Digests are canonicalized to +sha256:<hex>+ on write. Bare hex input is
  # accepted per CONTAINER-RUNTIME-019, but storing both forms would let the
  # same image register twice (identity uniqueness compares raw strings) and
  # would emit an invalid OCI reference from +#digest_reference+.
  def canonical_digest(value)
    normalized = value.to_s.strip.downcase
    return normalized if normalized.blank? || normalized.start_with?(SHA256_PREFIX)

    "#{SHA256_PREFIX}#{normalized}"
  end

  def identity_unique_within_account
    return unless account_id
    return if digest.blank? || registry.blank? || repository.blank? || architecture.blank?

    duplicate = self.class.where(
      account_id: account_id,
      registry: registry,
      repository: repository,
      digest: digest,
      architecture: architecture
    ).where.not(id: id).exists?

    return unless duplicate

    errors.add(:digest, "is already registered for this account, registry, repository, and architecture")
  end

  def immutable_identity_after_creation
    return unless persisted?
    return unless (changes.keys & IMMUTABLE_ATTRIBUTES).any?

    errors.add(:base, "agent image identity fields are immutable after creation")
  end

  def status_transition_is_allowed
    return unless will_save_change_to_status?

    from_status, to_status = status_change_to_be_saved
    return if from_status == to_status
    return if ALLOWED_STATUS_TRANSITIONS.fetch(from_status, []).include?(to_status)

    errors.add(:status, "cannot transition from #{from_status} to #{to_status}")
  end

  def status_audit_fields_present
    case status
    when "deprecated"
      require_lifecycle_field(:deprecated_at, "must be present when status is deprecated")
      require_lifecycle_field(:deprecation_reason, "must be present when status is deprecated")
    when "blocked"
      require_lifecycle_field(:blocked_at, "must be present when status is blocked")
      require_lifecycle_field(:blocked_reason, "must be present when status is blocked")
    end
  end

  def require_lifecycle_field(attribute, message)
    return if public_send(attribute).present?

    errors.add(attribute, message)
  end
end
