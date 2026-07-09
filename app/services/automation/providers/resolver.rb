# frozen_string_literal: true

module Automation
  module Providers
    # Resolver maps a {Project} to the concrete provider implementations
    # for each capability area (repository, work item, review).
    #
    # Implementations register themselves via {.register}. Automation
    # policy code looks up the provider for a project via
    # {.repository_for}, {.work_item_for}, and {.review_for}. When a
    # project has not opted into a specific provider type it defaults to
    # +:github+, matching the system's only concrete provider today.
    #
    # == Example registration
    #
    #   Automation::Providers::Resolver.register(
    #     :github,
    #     repository: ->(project, client: nil) { Github::RepositoryProvider.new(project, client: client) },
    #     work_item:  ->(project, client: nil) { Github::WorkItemProvider.new(project, client: client) },
    #     review:     ->(project, client: nil) { Github::ReviewProvider.new(project, client: client) }
    #   )
    #
    # Factories are invoked with the {Project} (and an optional +client:+)
    # on every resolution call. They MAY cache the returned instance per
    # project (e.g. memoize on the project), but the resolver itself is
    # intentionally stateless so that tests can register and clear
    # implementations independently.
    class Resolver
      CAPABILITIES = %i[repository work_item review].freeze

      UnknownProviderTypeError = Class.new(StandardError)
      UnknownCapabilityError = Class.new(StandardError)
      UnregisteredProviderError = Class.new(StandardError)

      class << self
        # Registers factories for a provider type. Factories are callables
        # (procs/lambdas/objects responding to +#call+) that accept a
        # {Project} and return an object that includes the corresponding
        # capability module ({RepositoryProvider}, {WorkItemProvider},
        # {ReviewProvider}).
        #
        # Passing +nil+ for a capability unregisters it.
        #
        # @param provider_type [Symbol] e.g. +:github+, +:gitlab+.
        # @param repository [#call, nil]
        # @param work_item [#call, nil]
        # @param review [#call, nil]
        # @return [void]
        def register(provider_type, repository: nil, work_item: nil, review: nil)
          entry = registry[provider_type.to_sym] ||= {}
          { repository:, work_item:, review: }.each do |capability, factory|
            next if factory.nil?

            validate_factory!(factory, capability)
            entry[capability] = factory
          end
        end

        # Removes all registered factories for +provider_type+. Primarily
        # useful in tests to isolate registration between examples.
        #
        # @param provider_type [Symbol, nil] When nil, clears every
        #   registration.
        # @return [void]
        def reset!(provider_type = nil)
          if provider_type.nil?
            registry.clear
          else
            registry.delete(provider_type.to_sym)
          end
        end

        # @return [Array<Symbol>] Registered provider type identifiers.
        def registered_provider_types
          registry.keys
        end

        # @param provider_type [Symbol]
        # @return [Boolean]
        def registered?(provider_type)
          registry.key?(provider_type.to_sym)
        end

        # Resolves the repository provider for +project+.
        #
        # When +client+ is supplied it is forwarded to the registered
        # factory so the resulting provider shares that client instead of
        # re-deriving one from the project. Signal collectors that already
        # hold a credential-aware client use this to keep a single client
        # across every provider call within a scan cycle.
        #
        # @param client [Object, nil] Optional provider client (e.g.
        #   {::GithubClient}) forwarded to the factory.
        # @return [Object] An instance including {RepositoryProvider}.
        def repository_for(project, client: nil)
          resolve(:repository, project, client:)
        end

        # Resolves the work-item provider for +project+. See
        # {.repository_for} for the +client:+ forwarding contract.
        #
        # @return [Object] An instance including {WorkItemProvider}.
        def work_item_for(project, client: nil)
          resolve(:work_item, project, client:)
        end

        # Resolves the review provider for +project+. See
        # {.repository_for} for the +client:+ forwarding contract.
        #
        # @return [Object] An instance including {ReviewProvider}.
        def review_for(project, client: nil)
          resolve(:review, project, client:)
        end

        # The provider type a project is configured to use. Falls back to
        # +:github+ for projects that have not opted in to an alternate
        # provider (the system's only concrete provider today).
        #
        # Projects signal their provider type by defining a +#provider_type+
        # method returning a Symbol or String. Deferring to a duck-typed
        # method keeps this resolver usable in tests and future codepaths
        # before a database column is introduced.
        #
        # @param project [Object]
        # @return [Symbol]
        def provider_type_for(project)
          raw = project.respond_to?(:provider_type) ? project.provider_type : nil
          raw.present? ? raw.to_sym : :github
        end

        private

        def registry
          @registry ||= {}
        end

        def resolve(capability, project, client: nil)
          raise UnknownCapabilityError, capability.inspect unless CAPABILITIES.include?(capability)

          provider_type = provider_type_for(project)
          entry = registry[provider_type] or
            raise UnknownProviderTypeError,
              "No providers registered for provider_type #{provider_type.inspect}"

          factory = entry[capability] or
            raise UnregisteredProviderError,
              "No #{capability} provider registered for provider_type #{provider_type.inspect}"

          factory.call(project, client:)
        end

        def validate_factory!(factory, capability)
          return if factory.respond_to?(:call)

          raise ArgumentError,
            "#{capability} factory must respond to #call (got #{factory.class})"
        end
      end
    end
  end
end
