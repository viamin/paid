# frozen_string_literal: true

module AppleVerification
  # Authenticated, fixed-vocabulary boundary deployed on the macOS worker.
  # Its input deliberately cannot describe host commands, paths, or mounts.
  # @spec APPLE-WORKER-001
  # @spec APPLE-WORKER-002
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
