# iOS background behavior

iOS suspends an app's network connections shortly after it leaves the
foreground. Porthole keeps its WebSocket to the daemon open while the app is
visible and for the grace period iOS allows afterwards. After that nothing can
arrive from the daemon directly.

- With the app open, permission prompts and "needs input" states appear live.
- With the phone locked or the app in the background, nothing arrives until
  you open the app again. The app then reconnects and shows the current state.
- Android can keep the connection alive with a foreground service; see
  [Stay connected in the background](../getting-started/app.md#settings).

The only way to wake an iOS app from outside is Apple's push service, which
requires a server holding the app's push key. That is the role of the push
relay: the daemon sends an encrypted notice through the relay, the phone
receives it as a notification, and the app fetches the details from your
machine when you open it. See [Push notifications](../guide/push.md).
