# TODO

Non-urgent cleanup and polish items.

- Extract `updateResultSignature(_:)` helper so update-result deduplication uses one signature formula.
- Replace deprecated `statusItem.view` usage with `statusItem.button`.
- Move daemon teardown settling off the main thread so rare `Quit -> Open` recovery does not block startup UI.
- Add clearer menu/status feedback for daemon stopped/starting states, especially when the user cancels the administrator prompt.
