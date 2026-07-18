# frozen_string_literal: true

module Screenshots
  # Registry of UI file patterns for different web frameworks.
  #
  # Each framework defines:
  # - patterns: regexps matching files that affect browser-rendered UI
  # - exclusions: regexps for files that match patterns but should be skipped
  module FrameworkPatterns
    RAILS = {
      patterns: [
        %r{\Aapp/views/},
        %r{\Aapp/javascript/},
        %r{\Aapp/assets/stylesheets/},
        %r{\Aapp/assets/builds/},
        %r{\Aapp/helpers/.*_helper\.rb\z},
        %r{\Aapp/components/},
        %r{\Aapp/frontend/},
        %r{\Aconfig/locales/.*\.yml\z},
        %r{\Aapp/controllers/(?!concerns/|api/).*_controller\.rb\z},
        %r{\Apublic/.*\.(?:html|png|svg|ico|webmanifest)\z}
      ].freeze,
      exclusions: [
        %r{\Aapp/views/devise/mailer/},
        %r{\Aapp/views/layouts/mailer(?:\.(?:html|text))?\.erb\z},
        %r{\Aapp/views/pwa/},
        %r{\Aconfig/locales/devise\.},
        %r{\Aapp/controllers/health_controller\.rb\z},
        %r{\Aapp/controllers/operator_console_access_controller\.rb\z}
      ].freeze
    }.freeze

    NEXTJS = {
      patterns: [
        %r{\Aapp/(?:.+/)?page\.[jt]sx?\z},
        %r{\Aapp/(?:.+/)?layout\.[jt]sx?\z},
        %r{\Aapp/(?:.+/)?loading\.[jt]sx?\z},
        %r{\Aapp/(?:.+/)?error\.[jt]sx?\z},
        %r{\Aapp/(?:.+/)?globals\.(?:css|scss|sass|less)\z},
        %r{\Aapp/(?:.+/)?[^/]+\.module\.(?:css|scss|sass|less)\z},
        %r{\Asrc/app/(?:.+/)?page\.[jt]sx?\z},
        %r{\Asrc/app/(?:.+/)?layout\.[jt]sx?\z},
        %r{\Asrc/app/(?:.+/)?loading\.[jt]sx?\z},
        %r{\Asrc/app/(?:.+/)?error\.[jt]sx?\z},
        %r{\Asrc/app/(?:.+/)?globals\.(?:css|scss|sass|less)\z},
        %r{\Asrc/app/(?:.+/)?[^/]+\.module\.(?:css|scss|sass|less)\z},
        %r{\Apages/.*\.[jt]sx?\z},
        %r{\Asrc/pages/.*\.[jt]sx?\z},
        %r{\Acomponents/},
        %r{\Astyles/},
        %r{\Apublic/.*\.(?:html|png|svg|ico|webmanifest)\z},
        %r{\Asrc/components/},
        %r{\Asrc/styles/}
      ].freeze,
      exclusions: [
        %r{\Aapp/api/},
        %r{\Asrc/app/api/},
        %r{\Apages/api/},
        %r{\Asrc/pages/api/},
        %r{\Apublic/robots\.txt\z}
      ].freeze
    }.freeze

    DJANGO = {
      patterns: [
        %r{\Atemplates/},
        %r{/templates/},
        %r{\Astatic/},
        %r{/static/},
        %r{\.html\z}
      ].freeze,
      exclusions: [].freeze
    }.freeze

    PHOENIX = {
      patterns: [
        %r{\Alib/[^/]+_web/live/},
        %r{\Alib/[^/]+_web/controllers/},
        %r{\Alib/[^/]+_web/components/},
        %r{\Alib/[^/]+_web/templates/},
        %r{\Alib/[^/]+_web/views/},
        %r{\Alib/[^/]+_web/router\.ex\z},
        %r{\Alib/[^/]+_web/endpoint\.ex\z},
        %r{\Aassets/js/},
        %r{\Aassets/css/},
        %r{\Aassets/vendor/},
        %r{\Aconfig/.*\.exs?\z},
        %r{/[^/]+_web/live/},
        %r{/[^/]+_web/controllers/},
        %r{/[^/]+_web/components/},
        %r{/[^/]+_web/templates/}
      ].freeze,
      exclusions: [
        %r{\Aassets/node_modules/},
        %r{\Adeps/},
        %r{\A_build/}
      ].freeze
    }.freeze

    GENERIC = {
      patterns: [
        %r{\.(?:html|css|scss|less|sass|vue|jsx|tsx|svelte)\z},
        %r{\Apublic/},
        %r{\Astatic/},
        %r{\Atemplates/},
        %r{\Asrc/components/},
        %r{\Acomponents/},
        %r{\Astyles/}
      ].freeze,
      exclusions: [].freeze
    }.freeze

    REGISTRY = {
      rails: RAILS,
      nextjs: NEXTJS,
      django: DJANGO,
      phoenix: PHOENIX,
      generic: GENERIC
    }.freeze

    # @param framework [Symbol] framework identifier
    # @return [Hash] with :patterns and :exclusions arrays
    def self.for(framework)
      REGISTRY.fetch(framework) do
        raise ArgumentError, "Unknown framework: #{framework}. Known frameworks: #{REGISTRY.keys.join(', ')}"
      end
    end
  end
end
