package com.hermesagent.hermes_android

/** True while an Ares activity is resumed.
 *
 * The push bridge runs in the same process as the UI, so it can skip posting a
 * notification the user is already looking at. A standalone object keeps the
 * JVM unit tests from loading MainActivity and the Flutter embedding. */
internal object AppVisibility {
    @Volatile var foreground = false
}
