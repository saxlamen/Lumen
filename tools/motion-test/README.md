# motion test overlay

Double-click `lumen-motion-test.command` (default 75 seconds; pass a number of seconds to change
it) and it overlays a full-screen animated window on **every** display: a moving box, a sweeping
colour bar, and a clock/frame counter that changes every 1/60s.

Without moving content, ScreenCaptureKit has nothing new to capture and the encoder takes the
"re-encode the last frame" shortcut, which makes encode rate, encoder output latency and frame
processing latency readings meaningless. With the overlay running, every frame is real work, so
the numbers in the log mean something. Ctrl-C ends it early.
