# frozen_string_literal: true

module Containers
  # Shared result object for all container service method returns.
  #
  # Used by Provision, ProvisionForChat, and ChatSessionManager.
  # Provision::Result is an alias for this class.
  class Result
    attr_reader :data, :error

    def initialize(success:, data: {}, error: nil)
      @success = success
      @data = data
      @error = error
    end

    def success?
      @success
    end

    def failure?
      !@success
    end

    def [](key)
      data[key]
    end

    def self.success(**data)
      new(success: true, data: data)
    end

    def self.failure(error:, **data)
      new(success: false, data: data, error: error)
    end
  end
end
