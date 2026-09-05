/**
 * @file src/platform/macos/gamepad_bridge.mm
 * @brief Bridge native HID and keyboard/mouse fallback controllers to the input pipeline.
 */
#include "gamepad_bridge.h"

#include "gamepad.h"
#include "hid_gamepad.h"
#include "src/logging.h"
#include "src/platform/virtualhid_input.h"

namespace platf::macos {
  namespace {
    /**
     * @brief Own a native HID device or the legacy keyboard/mouse emulation device.
     */
    class native_gamepad_t final: public gamepad_device_t {
    public:
      HIDGamepad *hid = nil;  ///< Native controller when macOS permits virtual HID creation.
      MacOSGamepad *emulated = nil;  ///< Keyboard/mouse fallback when HID creation fails.

      /**
       * @brief Release held buttons before destroying either backend.
       */
      ~native_gamepad_t() override {
        [hid disconnect];
        [hid release];
        [emulated disconnect];
        [emulated release];
      }

      /**
       * @brief Forward the client's complete state to the selected backend.
       * @param state Client controller state.
       */
      void update(const gamepad_state_t &state) override {
        if (hid) {
          [hid updateState:state.buttonFlags
                leftStickX:state.lsX
                leftStickY:state.lsY
               rightStickX:state.rsX
               rightStickY:state.rsY
               leftTrigger:state.lt
              rightTrigger:state.rt];
        } else {
          [emulated updateState:state.buttonFlags
                     leftStickX:state.lsX
                     leftStickY:state.lsY
                    rightStickX:state.rsX
                    rightStickY:state.rsY
                    leftTrigger:state.lt
                   rightTrigger:state.rt];
        }
      }
    };

    /**
     * @brief Try native HID first, then retain main's keyboard/mouse compatibility mode.
     * @param index Global controller slot.
     * @return Controller device, or null if neither backend can initialize.
     */
    std::shared_ptr<gamepad_device_t> create_native_gamepad(int index) {
      auto device = std::make_shared<native_gamepad_t>();
      device->hid = [[HIDGamepad alloc] initWithIndex:index];
      if (device->hid && [device->hid createDevice]) {
        BOOST_LOG(info) << "macOS controller " << index << ": native HID";
        return device;
      }
      [device->hid release];
      device->hid = nil;
      device->emulated = [[MacOSGamepad alloc] initWithIndex:index];
      if (!device->emulated) {
        return nullptr;
      }
      BOOST_LOG(warning) << "macOS controller " << index << ": virtual HID unavailable; using keyboard/mouse emulation";
      return device;
    }
  }  // namespace

  int allocate_gamepad_slot(gamepad_slots_t &slots, int index, const gamepad_factory_t &factory) {
    if (index < 0 || static_cast<std::size_t>(index) >= slots.size() || slots[index]) {
      return -1;
    }
    slots[index] = factory(index);
    return slots[index] ? 0 : -1;
  }

  std::shared_ptr<gamepad_device_t> find_gamepad_slot(const gamepad_slots_t &slots, int index) {
    if (index < 0 || static_cast<std::size_t>(index) >= slots.size()) {
      return nullptr;
    }
    return slots[index];
  }

  void release_gamepad_slot(gamepad_slots_t &slots, int index) {
    if (index >= 0 && static_cast<std::size_t>(index) < slots.size()) {
      slots[index].reset();
    }
  }
}  // namespace platf::macos

namespace platf {
  /**
   * @brief Allocate a native macOS controller or keyboard/mouse fallback.
   */
  int alloc_gamepad(input_t &input, const gamepad_id_t &id, const gamepad_arrival_t &metadata, feedback_queue_t feedback_queue) {
    auto &context = virtualhid::get_input_context(input);
    if (!context.runtime) {
      return -1;
    }
    if (context.runtime->capabilities().supports_gamepad) {
      return virtualhid::alloc_gamepad(context, id, metadata, std::move(feedback_queue));
    }
    return macos::allocate_gamepad_slot(context.macos_gamepads, id.globalIndex, macos::create_native_gamepad);
  }

  /**
   * @brief Preserve an existing controller when the client reconnects.
   */
  int rebind_gamepad(input_t &input, const gamepad_id_t &id, feedback_queue_t feedback_queue) {
    auto &context = virtualhid::get_input_context(input);
    if (macos::find_gamepad_slot(context.macos_gamepads, id.globalIndex)) {
      // Native macOS devices do not produce feedback; retain their reconnect state.
      return 0;
    }
    return virtualhid::rebind_gamepad(context, id, std::move(feedback_queue));
  }

  /**
   * @brief Disconnect a controller and release held input.
   */
  void free_gamepad(input_t &input, int nr) {
    auto &context = virtualhid::get_input_context(input);
    macos::release_gamepad_slot(context.macos_gamepads, nr);
    virtualhid::free_gamepad(context, nr);
  }

  /**
   * @brief Forward state to an active macOS controller.
   */
  void gamepad_update(input_t &input, int nr, const gamepad_state_t &state) {
    if (const auto device = macos::find_gamepad_slot(virtualhid::get_input_context(input).macos_gamepads, nr)) {
      device->update(state);
    } else {
      virtualhid::gamepad_update(virtualhid::get_input_context(input), nr, state);
    }
  }

  /**
   * @brief Ignore unsupported controller touch reports.
   */
  void gamepad_touch(input_t &input, const gamepad_touch_t &touch) {
    virtualhid::gamepad_touch(virtualhid::get_input_context(input), touch);
  }

  /**
   * @brief Ignore unsupported controller motion reports.
   */
  void gamepad_motion(input_t &input, const gamepad_motion_t &motion) {
    virtualhid::gamepad_motion(virtualhid::get_input_context(input), motion);
  }

  /**
   * @brief Ignore unsupported controller battery reports.
   */
  void gamepad_battery(input_t &input, const gamepad_battery_t &battery) {
    virtualhid::gamepad_battery(virtualhid::get_input_context(input), battery);
  }
}  // namespace platf
