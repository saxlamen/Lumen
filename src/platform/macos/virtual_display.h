/**
 * @file src/platform/macos/virtual_display.h
 * @brief Declarations for CGVirtualDisplay-based virtual display management on macOS.
 */
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stdint.h>

/**
 * @brief Create or reuse a persistent virtual display with the specified resolution and refresh rate.
 * @param width Display width in pixels.
 * @param height Display height in pixels.
 * @param fps Refresh rate in Hz.
 * @return The CGDirectDisplayID of the display, or 0 on failure.
 */
uint32_t virtual_display_create(int width, int height, int fps);

/**
 * @brief Restore the original main display while keeping the virtual display alive for reuse.
 */
void virtual_display_deactivate(void);

/**
 * @brief Destroy the currently active virtual display.
 */
void virtual_display_destroy(void);

/**
 * @brief Check whether the most recent virtual_display_create call reused an existing display.
 * @return true if an existing persistent virtual display was reused; false if newly created.
 */
bool virtual_display_was_reused(void);

/**
 * @brief Get the display ID of the currently active virtual display.
 * @return The CGDirectDisplayID, or 0 if no virtual display is active.
 */
uint32_t virtual_display_get_id(void);

#ifdef __cplusplus
}
#endif
