# iOS background behavior

iOS suspends an app's network connections shortly after it leaves the
foreground. Porthole keeps the WebSocket open while the app is visible and for
the short grace period iOS allows afterwards; after that no notifications can
arrive from the daemon directly.

What that means in practice:

- With the app open, permission prompts and "needs input" states appear live.
- With the phone locked or the app in the background, nothing arrives until
  you open the app again. Porthole reconnects automatically and shows the
  current state immediately.
- Android can keep the connection alive with a foreground service (a
  persistent notification), so Android users get timely alerts without any
  cloud service.

The only way to wake an iOS app from the outside is Apple's push service,
which requires a server holding the app's push key. That is what the optional
push relay is for: the daemon sends an encrypted wake-up through a small
relay you run or are given a URL for (see [Push notifications](../guide/push.md)), the phone wakes, brings the VPN up on
demand, and fetches the details from your machine. Nothing about your sessions leaves the VPN; the
relay sees a device token and ciphertext.
