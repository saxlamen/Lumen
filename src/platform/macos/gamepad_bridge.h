/**
 * @file src/platform/macos/gamepad_bridge.h
 * @brief Native macOS controller lifecycle and injectable device creation.
 */
#pragma once

#include "src/platform/common.h"

#include <functional>
#include <memory>
#include <vector>

namespace platf::macos {
  /**
   * @brief Controller device that releases any held input when destroyed.
   */
  class gamepad_device_t {
  public:
    /**
     * @brief Disconnect the controller and release its resources.
     */
    virtual ~gamepad_device_t() = default;

    /**
     * @brief Submit a complete controller state.
     * @param state Buttons, sticks and triggers received from the client.
     */
    virtual void update(const gamepad_state_t &state) = 0;
  };

  using gamepad_slots_t = std::vector<std::shared_ptr<gamepad_device_t>>;  ///< Devices indexed by global controller slot.
  using gamepad_factory_t = std::function<std::shared_ptr<gamepad_device_t>(int)>;  ///< Factory for a native or emulated controller.

  /**
   * @brief Allocate an unused controller slot without replacing an active device.
   * @param slots Controller storage belonging to the input context.
   * @param index Global controller index.
   * @param factory Device constructor; may return null on failure.
   * @return Zero on success, or minus one for an invalid, occupied or unavailable slot.
   */
  int allocate_gamepad_slot(gamepad_slots_t &slots, int index, const gamepad_factory_t &factory);

  /**
   * @brief Find an active device without indexing outside the slot array.
   * @param slots Controller storage belonging to the input context.
   * @param index Global controller index.
   * @return Active device, or null for an invalid or empty slot.
   */
  std::shared_ptr<gamepad_device_t> find_gamepad_slot(const gamepad_slots_t &slots, int index);

  /**
   * @brief Disconnect a controller, ignoring invalid or already empty slots.
   * @param slots Controller storage belonging to the input context.
   * @param index Global controller index.
   */
  void release_gamepad_slot(gamepad_slots_t &slots, int index);
}  // namespace platf::macos
