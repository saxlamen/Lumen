# FFmpeg experiments that were not shipped

These are the patches that led to the one that shipped. They cost a build each to discover, so
they are kept here rather than in a scratch directory that a reboot would take away. None of
them are applied by `build-bundle.sh` or by CI: the build only applies
`../build-deps/patches/FFmpeg/FFmpeg/videotoolbox/01-frame-drain.patch`, which is the behaviour
change Lumen actually depends on (`frame_drain` in the encoder, the reason a drained frame is
reported instead of left behind).

| Patch | What it was for | Why it is not in the build |
| --- | --- | --- |
| `01-vt-lag1-drain.patch` | The first version of the drain fix, written against the encoder's internal queue. | Superseded by the smaller option-based patch; the shipped one is the one CI applies. |
| `02-vt-frame-drain-option.patch` | Turns the same fix into a runtime option so it can be switched per stream. | This is the shape that shipped, kept here as the original submission text. |
| `01-add-bgra1010102-rgba1010102.patch` | Adds the 10-bit pixel formats the display pipeline produces on Apple Silicon, so a 10-bit stream could reach the encoder without conversion. | Conversion to 8-bit turned out not to be on the critical path, so the format support bought nothing measurable. |
| `01-explicit-intmath.patch` | Forces integer math in the rate control to stop a build-dependent rounding difference. | The comparison it protects was a local experiment, not a shipped code path. |
| `02-remove-register.patch` | Drops a `register` keyword a newer toolchain warns about. | A toolchain-local annoyance; upstream keeps the keyword. |
