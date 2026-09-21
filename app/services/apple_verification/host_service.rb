# frozen_string_literal: true

module AppleVerification
  # Authenticated, fixed-vocabulary boundary deployed on the macOS worker.
  # Its input deliberately cannot describe host commands, paths, or mounts.
  # @spec APPLE-WORKER-008
  # @spec APPLE-WORKER-009
  # @spec APPLE-WORKER-010
  class HostService
    API_VERSION = "v1"
    OPERATIONS = %w[readiness clone start inspect stop destroy inventory].freeze
    FORBIDDEN_KEYS = %w[
      command commands executable exec script shell argv
      path paths repository repository_path repo_path host_path
      mount mounts host_mount host_mounts volume volumes
    ].freeze
    CLONE_KEYS = %w[request_id image_id ownership_tags].freeze
    START_KEYS = %w[request_id vm_id profile_id].freeze
    VM_KEYS = %w[request_id vm_id].freeze
    INVENTORY_KEYS = %w[ownership_tags].freeze
    PAID_TAG_PREFIX = "paid."
    RESOURCE_TAG = "paid.resource"
    APPLE_VM_RESOURCE = "apple_vm"
    REQUIRED_INVENTORY_TAGS = ExecutionRunners::REQUIRED_RECONCILIATION_TAG_NAMES.map do |name|
      "#{PAID_TAG_PREFIX}#{name}"
    end.freeze

    AuthenticationError = Class.new(StandardError)
    UnsupportedRequestError = Class.new(ArgumentError)
    UnsafeRequestError = Class.new(ArgumentError)

    def initialize(provider:, token:, approved_images:)
      @provider = provider
      @token = token.to_s
      @approved_images = Array(approved_images).map(&:to_s).freeze
    end

    def call(version:, operation:, payload:, token:)
      authenticate!(token)
      validate!(version:, operation:, payload:)
      dispatch(operation.to_s, payload.stringify_keys)
    end

    private

    attr_reader :provider, :token, :approved_images

    def authenticate!(candidate)
      valid = candidate.to_s
      raise AuthenticationError, "macOS host request is not authenticated" if token.blank? || valid.bytesize != token.bytesize ||
        !ActiveSupport::SecurityUtils.secure_compare(valid, token)
    end

    def validate!(version:, operation:, payload:)
      raise UnsupportedRequestError, "Unsupported host API version: #{version}" unless version == API_VERSION
      raise UnsupportedRequestError, "Unsupported host lifecycle operation: #{operation}" unless OPERATIONS.include?(operation.to_s)
      raise UnsafeRequestError, "Host request payload must be an object" unless payload.is_a?(Hash)

      validate_payload_keys!(operation.to_s, payload.stringify_keys)
      reject_forbidden_content!(payload)
      validate_image!(payload) if operation.to_s == "clone"
      validate_clone!(payload) if operation.to_s == "clone"
      validate_inventory!(payload) if operation.to_s == "inventory"
    end

    def validate_payload_keys!(operation, payload)
      allowed = {
        "readiness" => [], "clone" => CLONE_KEYS, "start" => START_KEYS,
        "inspect" => VM_KEYS, "stop" => VM_KEYS, "destroy" => VM_KEYS,
        "inventory" => INVENTORY_KEYS
      }.fetch(operation)
      unknown = payload.keys - allowed
      raise UnsafeRequestError, "Host request contains unsupported fields: #{unknown.join(', ')}" if unknown.any?
    end

    def reject_forbidden_content!(value)
      case value
      when Hash
        value.each do |key, child|
          raise UnsafeRequestError, "Host request contains forbidden field: #{key}" if FORBIDDEN_KEYS.include?(key.to_s.downcase)

          reject_forbidden_content!(child)
        end
      when Array then value.each { |child| reject_forbidden_content!(child) }
      end
    end

    def validate_image!(payload)
      image_id = payload["image_id"].to_s
      raise UnsafeRequestError, "Host request image is not approved" unless approved_images.include?(image_id)
    end

    def validate_clone!(payload)
      return if paid_reconciliation_ownership_tags?(payload["ownership_tags"])

      raise UnsafeRequestError, "Host clone must use the Paid reconciliation tag set"
    end

    def validate_inventory!(payload)
      ownership_tags = payload["ownership_tags"]
      return if ownership_tags.is_a?(Hash) && paid_reconciliation_tags?(ownership_tags)

      raise UnsafeRequestError, "Host inventory must use the Paid reconciliation tag set"
    end

    def paid_reconciliation_tags?(ownership_tags)
      tag_names = ownership_tags.keys.map(&:to_s)
      tag_names.all? { |name| name.start_with?(PAID_TAG_PREFIX) } &&
        REQUIRED_INVENTORY_TAGS.all? { |name| tag_names.include?(name) }
    end

    def paid_reconciliation_ownership_tags?(ownership_tags)
      return false unless ownership_tags.is_a?(Hash) && paid_reconciliation_tags?(ownership_tags)

      tags = ownership_tags.stringify_keys
      REQUIRED_INVENTORY_TAGS.all? { |name| tags[name].present? } && tags[RESOURCE_TAG] == APPLE_VM_RESOURCE
    end

    def dispatch(operation, payload)
      case operation
      when "readiness" then provider.readiness
      when "clone" then provider.clone(**payload.symbolize_keys)
      when "start" then provider.start(**payload.symbolize_keys)
      when "inspect" then provider.inspect(**payload.symbolize_keys)
      when "stop" then provider.stop(**payload.symbolize_keys)
      when "destroy" then provider.destroy(**payload.symbolize_keys)
      when "inventory" then provider.inventory(**payload.symbolize_keys)
      end
    end
  end
end
