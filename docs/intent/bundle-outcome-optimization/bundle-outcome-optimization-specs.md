# EARS Specs: Bundle Outcome Optimization

> Testable claims for configuration-bundle selection and surrogate scoring.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **BUNDLE-OPT-001** — When selecting a configuration bundle, the system
  SHALL rank candidate experiment combinations by predicted objective score and
  expected improvement, record the chosen selection mode/context, and enforce
  the configured exploration budgets before choosing an exploratory bundle.
  *Code:* `ConfigurationBundles::Optimizer`.

- [x] **BUNDLE-OPT-002** — When predicting bundle outcomes, the system SHALL
  use the production weighted similarity/prior surrogate to return predicted
  objective/quality/success values together with uncertainty for the queried
  bundle definition.
  *Code:* `ConfigurationBundles::SurrogateOutcomeModel`.
