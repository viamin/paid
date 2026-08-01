# frozen_string_literal: true

module HealthChecks
  class Cache
    KEY_PREFIX = "health_check/project"

    class << self
      def read(project)
        Rails.cache.read(cache_key(project))
      end

      def write(project, result)
        Rails.cache.write(cache_key(project), result)
      end

      def delete(project)
        Rails.cache.delete(cache_key(project))
      end

      private

      def cache_key(project)
        "#{KEY_PREFIX}/#{project.id}"
      end
    end
  end
end
