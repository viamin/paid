# frozen_string_literal: true

module Previews
  # Integration point for the preview container lifecycle (RDR-045, SUB-7).
  #
  # The real backend provisions a Docker container with the target branch
  # checked out, starts the detected web app, and bridges its port back to the
  # Rails host via a rathole tunnel. That Docker/rathole integration is built
  # in a follow-up; until it lands, {Simulated} records a stable pseudo
  # container id so the preview UI and reverse proxy are fully functional and
  # testable end to end. Swapping in the real backend requires no controller or
  # view changes — only this object.
  module ContainerBackend
    Outcome = Struct.new(:container_id, :app_port, keyword_init: true)

    module Simulated
      module_function

      def start(session)
        Rails.logger.info(
          message: "previews.container_backend.simulated_start",
          preview_session_id: session.id,
          branch_name: session.branch_name
        )
        Outcome.new(container_id: "preview-#{session.token[0, 12]}", app_port: default_app_port(session))
      end

      def stop(session)
        Rails.logger.info(
          message: "previews.container_backend.simulated_stop",
          preview_session_id: session.id,
          container_id: session.container_id
        )
        true
      end

      def default_app_port(session)
        # Phoenix listens on 4000; Rails/Sinatra/etc. on 3000. The simulated
        # backend keeps the app on its framework's conventional port.
        session.framework == "phoenix" ? 4000 : 3000
      end
    end
  end
end
