# frozen_string_literal: true

module SolidCable
  module ReloadSafeShutdown
    private
      def unloading?
        ActiveSupport::Dependencies.interlock.raw_state do |state|
          state.fetch(Thread.current, {})[:exclusive]
        end
      end

      def finish_shutdown
        thread.join
        background.shutdown
        background.wait_for_termination
      end

    public
      # @spec RAILS-CONTROL-PLANE-009
      def shutdown
        return super unless unloading?

        queue.close
        Thread.new { finish_shutdown }
      end
  end
end

SolidCable::BatchedBroadcaster.prepend(SolidCable::ReloadSafeShutdown)
