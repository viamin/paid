# EARS Specs: Runner Weight Controls (Settings UI)

> Testable claims for the client-side behavior of the manual weight inputs on
> the Runner Priority settings page. Status markers: `[x]` implemented ·
> `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r RUNNER-WEIGHTS-001`).

- [x] **RUNNER-WEIGHTS-001** — When the user toggles the "Auto-balance
  weights based on usage quotas" checkbox on the Runner Priority settings
  page, the per-runner weight number inputs SHALL immediately become
  disabled (checkbox checked) or enabled (checkbox unchecked), and the
  "Auto-weighting is active..." notice SHALL show or hide to match, without
  requiring a form submit or page reload.
  *Code:* `app/javascript/controllers/runner_weights_controller.js`,
  `app/views/runners/_settings.html.erb`.
  *Test:* `spec/system/runners/runner_weights_toggle_spec.rb`.
