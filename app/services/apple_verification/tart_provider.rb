# frozen_string_literal: true

module AppleVerification
  # Provider-neutral Apple worker implementation. Tart and Softnet adapters are
  # injected so project-controlled input can never become a host command.
  # @spec APPLE-WORKER-003
  class TartProvider
    PROVIDER_NAME = "tart"
    REQUEST_ID_TAG = "paid.request_id"

    def initialize(tart:, softnet:, profiles:)
      @tart = tart
      @softnet = softnet
      @profiles = profiles.deep_stringify_keys.freeze
      @responses = {}
      @response_lock = Mutex.new
    end

    def readiness
      tart.readiness.slice("cpu", "memory", "disk", "images", "network", "guest_connection")
    end

    def clone(request_id:, image_id:, ownership_tags:)
      idempotently("clone", request_id) do
        clone_for_request(request_id:, image_id:, ownership_tags:)
      end
    end

    def start(request_id:, vm_id:, profile_id:)
      idempotently("start", request_id) do
        profile = profiles.fetch(profile_id.to_s) { raise ArgumentError, "Unknown Apple worker profile: #{profile_id}" }
        softnet.configure(vm_id:, network: profile.fetch("network"))
        tart.start(vm_id:, **profile.slice("cpu_cores", "memory_mib", "disk_gb").symbolize_keys)
      end
    end

    def inspect(request_id:, vm_id:)
      idempotently("inspect", request_id) { tart.inspect(vm_id:) }
    end

    def stop(request_id:, vm_id:)
      idempotently("stop", request_id) { tart.stop(vm_id:); { "vm_id" => vm_id, "state" => "stopped" } }
    end

    def destroy(request_id:, vm_id:)
      idempotently("destroy", request_id) { tart.destroy(vm_id:); { "vm_id" => vm_id, "state" => "destroyed" } }
    end

    def inventory(ownership_tags:)
      tart.inventory(ownership_tags:).map do |resource|
        {
          "vm_id" => resource.fetch("vm_id"),
          "tags" => resource.fetch("tags", {}),
          "state" => resource["state"],
          "image_id" => resource["image_id"]
        }
      end
    end

    private

    attr_reader :tart, :softnet, :profiles, :responses, :response_lock

    def idempotently(operation, request_id)
      request_key = request_id.to_s
      raise ArgumentError, "Host lifecycle request id is required" if request_key.blank?

      response_lock.synchronize do
        key = [ operation, request_key ]
        responses.fetch(key) { responses[key] = yield }
      end
    end

    def clone_for_request(request_id:, image_id:, ownership_tags:)
      existing_clone(request_id) || tart.clone(image_id:, ownership_tags: ownership_tags.merge(REQUEST_ID_TAG => request_id.to_s))
    end

    def existing_clone(request_id)
      clones = tart.inventory(ownership_tags: { REQUEST_ID_TAG => request_id.to_s })
      return if clones.empty?
      return clones.first if clones.one?

      raise ArgumentError, "Multiple Apple VMs exist for lifecycle request: #{request_id}"
    end
  end
end
