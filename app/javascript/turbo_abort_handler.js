// Turbo deliberately aborts an eager frame request when a user selects a
// different Inbox row before the initial detail finishes loading. Chrome
// reports that expected cancellation as an unhandled rejection unless it is
// consumed here, which incorrectly makes the browser test and the console
// treat the successful replacement navigation as a failure.
// @spec OPERATOR-INBOX-025
window.addEventListener("unhandledrejection", (event) => {
  if (event.reason?.name === "AbortError") event.preventDefault()
})
