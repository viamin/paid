# frozen_string_literal: true

# @spec APPLE-VERIFY-001
# @spec APPLE-VERIFY-002
class AppleVerificationImage < ApplicationRecord
  SmokeTestRequiredError = Class.new(StandardError)
  STATUSES = %w[candidate active deprecated retired revoked].freeze
  ALLOWED_STATUS_TRANSITIONS = {
    "candidate" => %w[active revoked],
    "active" => %w[deprecated revoked],
    "deprecated" => %w[retired revoked],
    "retired" => %w[revoked],
    "revoked" => []
  }.freeze
  DIGEST_FORMAT = /\Asha256:[0-9a-f]{64}\z/
  IMMUTABLE_FACTS = %w[digest name toolchain resources network_capability gui_account smoke_test provenance account_id].freeze
  GUI_ACCOUNT_REQUIREMENTS = { "admin" => false, "apple_id" => false, "personal_data" => false, "host_credentials" => false, "persistent_secret_keychain" => false, "ready_gui_session" => true }.freeze
  TOOLCHAIN_KEYS = %w[macos_version macos_build xcode_version xcode_build sdk_versions simulator_runtimes executor_version].freeze
  RESOURCE_KEYS = %w[cpu_count memory_gib disk_gib].freeze

  belongs_to :account

  has_logidze

  before_validation :normalize_facts

  validates :name, presence: true, length: { maximum: 100 }
  validates :digest, presence: true, format: { with: DIGEST_FORMAT }
  validates :status, inclusion: { in: STATUSES }
  validate :toolchain_is_complete
  validate :resources_are_complete
  validate :network_capability_is_complete
  validate :gui_account_is_isolated
  validate :smoke_test_is_recorded
  validate :immutable_facts_after_publication, on: :update
  validate :status_transition_is_allowed
  validate :active_image_is_smoke_tested
  validate :lifecycle_audit_fields

  scope :active, -> { where(status: "active") }
  scope :schedulable, -> { active }

  STATUSES.each { |value| define_method("#{value}?") { status == value } }

  def schedulable?
    active?
  end

  def promote!
    return self if active?

    raise SmokeTestRequiredError, "a passing smoke test is required for promotion" unless passing_smoke_test?
    raise ArgumentError, "only candidate images can be promoted" unless candidate?

    update!(status: "active", promoted_at: Time.current)
    self
  end

  def deprecate!(reason:, retirement_at:)
    return self if deprecated?

    raise ArgumentError, "only active images can be deprecated" unless active?
    raise ArgumentError, "deprecation reason is required" if reason.to_s.strip.blank?
    raise ArgumentError, "retirement time is required" unless retirement_at.present?

    update!(status: "deprecated", deprecated_at: Time.current, deprecation_reason: reason.to_s.strip, retirement_at: retirement_at)
    self
  end

  def retire!(reason:)
    return self if retired?

    raise ArgumentError, "only deprecated images can be retired" unless deprecated?
    raise ArgumentError, "retirement reason is required" if reason.to_s.strip.blank?
    raise ArgumentError, "retirement time has not arrived" if retirement_at.blank? || retirement_at.future?

    update!(status: "retired", deprecation_reason: reason.to_s.strip)
    self
  end

  def revoke!(reason:)
    raise ArgumentError, "revocation reason is required" if reason.to_s.strip.blank?
    return self if revoked?

    update!(status: "revoked", revoked_at: Time.current, revocation_reason: reason.to_s.strip)
    self
  end

  private

  def normalize_facts
    self.name = name.to_s.strip
    self.digest = digest.to_s.strip.downcase
    %w[toolchain resources network_capability gui_account smoke_test provenance].each do |attribute|
      value = public_send(attribute)
      public_send("#{attribute}=", value.deep_stringify_keys) if value.is_a?(Hash)
    end
  end

  def toolchain_is_complete
    errors.add(:toolchain, "must record all macOS, Xcode, SDK, runtime, and executor facts") unless object_with_keys?(toolchain, TOOLCHAIN_KEYS)
  end

  def resources_are_complete
    return errors.add(:resources, "must record CPU, memory, and disk envelope") unless object_with_keys?(resources, RESOURCE_KEYS)

    errors.add(:resources, "must use positive CPU, memory, and disk values") unless RESOURCE_KEYS.all? { |key| resources[key].to_i.positive? }
  end

  def network_capability_is_complete
    return errors.add(:network_capability, "must be an object") unless network_capability.is_a?(Hash)

    errors.add(:network_capability, "must declare a mechanism and enforced egress policy") unless network_capability["mechanism"].present? && network_capability["egress_enforced"] == true
  end

  def gui_account_is_isolated
    return errors.add(:gui_account, "must be an object") unless gui_account.is_a?(Hash)
    return if GUI_ACCOUNT_REQUIREMENTS.all? { |key, value| gui_account[key] == value }

    errors.add(:gui_account, "must declare a non-admin account without Apple ID, personal data, host credentials, or a persistent secret-bearing keychain")
  end

  def smoke_test_is_recorded
    errors.add(:smoke_test, "must record a boolean passed result") unless smoke_test.is_a?(Hash) && [ true, false ].include?(smoke_test["passed"])
  end

  def immutable_facts_after_publication
    changed_facts = changes.keys & IMMUTABLE_FACTS
    return unless persisted? && changed_facts.any?
    return if candidate? && changed_facts == [ "smoke_test" ]

    errors.add(:base, "Apple verification image facts are immutable after publication")
  end

  def status_transition_is_allowed
    return unless will_save_change_to_status?

    from_status, to_status = status_change_to_be_saved
    return if from_status.nil? && candidate?
    return if ALLOWED_STATUS_TRANSITIONS.fetch(from_status, []).include?(to_status)

    errors.add(:status, "cannot transition from #{from_status} to #{to_status}")
  end

  def active_image_is_smoke_tested
    return unless active?

    errors.add(:smoke_test, "must have passed before promotion") unless passing_smoke_test?
    errors.add(:promoted_at, "is required when active") if promoted_at.blank?
  end

  def lifecycle_audit_fields
    errors.add(:deprecation_reason, "is required when deprecated") if deprecated? && deprecation_reason.blank?
    errors.add(:deprecated_at, "is required when deprecated") if deprecated? && deprecated_at.blank?
    errors.add(:retirement_at, "is required when retired") if retired? && retirement_at.blank?
    errors.add(:retirement_at, "must have passed before the image can be retired") if retired? && retirement_at.present? && retirement_at.future?
    errors.add(:revocation_reason, "is required when revoked") if revoked? && revocation_reason.blank?
    errors.add(:revoked_at, "is required when revoked") if revoked? && revoked_at.blank?
  end

  def passing_smoke_test?
    smoke_test.is_a?(Hash) && smoke_test["passed"] == true
  end

  def object_with_keys?(value, keys)
    value.is_a?(Hash) && keys.all? { |key| value[key].present? }
  end
end
