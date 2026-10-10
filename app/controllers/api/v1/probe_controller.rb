# frozen_string_literal: true

module Api
  module V1
    # Stub probe route for bearer-auth verification while the inbox (#4239)
    # and chat (#4240) endpoints are unbuilt. Reflects the resolved request
    # context (bearer subject + tenant) so auth, tenant resolution, and the
    # SSE-before-bytes guarantee stay testable end to end.
    class ProbeController < BaseController
      include ActionController::Live

      # GET /api/v1/probe
      def show
        render json: {
          user_id: current_user.id,
          account_id: current_account.id
        }
      end

      # GET /api/v1/probe/stream — authenticates from the Authorization
      # header exactly like JSON requests before any stream bytes are
      # written (MOBILE-API-005). Emits several events so tests can prove
      # the rate limiter counts a stream once, not once per event.
      def stream
        response.headers["Content-Type"] = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"

        write_event("probe_start", { user_id: current_user.id, account_id: current_account.id })
        write_event("probe_event", { sequence: 1 })
        write_event("probe_event", { sequence: 2 })
        write_event("probe_complete", {})
      ensure
        response.stream.close
      end

      private

      def write_event(name, payload)
        response.stream.write("event: #{name}\ndata: #{payload.to_json}\n\n")
      end
    end
  end
end
