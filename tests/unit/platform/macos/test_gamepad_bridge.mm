/**
 * @file tests/unit/platform/macos/test_gamepad_bridge.mm
 * @brief Controller lifecycle and HID mapping tests without creating system input devices.
 */
#ifdef __APPLE__
  #include "../../../tests_common.h"
  #include "src/platform/macos/gamepad.h"
  #include "src/platform/macos/gamepad_bridge.h"
  #include "src/platform/macos/hid_gamepad.h"

  #include <objc/runtime.h>

namespace {
  /**
   * @brief Fake controller that records state and counts destruction.
   */
  class test_gamepad_t final: public platf::macos::gamepad_device_t {
  public:
    int &destroyed;  ///< Destruction counter owned by the test.
    platf::gamepad_state_t state {};  ///< Most recent submitted state.

    /**
     * @brief Attach the fake controller to its destruction counter.
     * @param counter Counter incremented on destruction.
     */
    explicit test_gamepad_t(int &counter):
        destroyed(counter) {}

    /**
     * @brief Record release of the controller.
     */
    ~test_gamepad_t() override {
      ++destroyed;
    }

    /**
     * @brief Record a client state without posting input to macOS.
     * @param value Client state to record.
     */
    void update(const platf::gamepad_state_t &value) override {
      state = value;
    }
  };
}  // namespace

/**
 * @brief Reject invalid and occupied slots, preserve reconnect identity, and release once.
 */
TEST(MacosGamepad, SlotLifecycle) {
  using namespace platf::macos;
  int destroyed = 0;
  int created = 0;
  gamepad_slots_t slots(2);
  const auto factory = [&](int index) {
    EXPECT_EQ(index, 1);
    ++created;
    return std::make_shared<test_gamepad_t>(destroyed);
  };
  EXPECT_EQ(allocate_gamepad_slot(slots, -1, factory), -1);
  EXPECT_EQ(allocate_gamepad_slot(slots, 2, factory), -1);
  EXPECT_EQ(created, 0);
  EXPECT_EQ(allocate_gamepad_slot(slots, 1, factory), 0);
  EXPECT_EQ(allocate_gamepad_slot(slots, 1, factory), -1);
  EXPECT_EQ(created, 1);
  EXPECT_EQ(find_gamepad_slot(slots, -1), nullptr);
  EXPECT_EQ(find_gamepad_slot(slots, 2), nullptr);
  EXPECT_EQ(find_gamepad_slot(slots, 0), nullptr);
  EXPECT_EQ(find_gamepad_slot(slots, 1), slots[1]);
  platf::gamepad_state_t state {};
  state.buttonFlags = 0x1000;
  find_gamepad_slot(slots, 1)->update(state);
  EXPECT_EQ(static_cast<test_gamepad_t *>(slots[1].get())->state.buttonFlags, 0x1000);
  release_gamepad_slot(slots, -1);
  release_gamepad_slot(slots, 2);
  EXPECT_EQ(destroyed, 0);
  release_gamepad_slot(slots, 1);
  release_gamepad_slot(slots, 1);
  EXPECT_EQ(destroyed, 1);
  EXPECT_EQ(find_gamepad_slot(slots, 1), nullptr);
  EXPECT_EQ(allocate_gamepad_slot(slots, 1, [](int) {
              return nullptr;
            }),
            -1);
  EXPECT_EQ(find_gamepad_slot(slots, 1), nullptr);
  EXPECT_EQ(allocate_gamepad_slot(slots, 1, factory), 0);
  slots.clear();
  EXPECT_EQ(destroyed, 2);
}

/**
 * @brief Preserve all analog endpoints and the packed native report layout.
 */
TEST(MacosGamepad, HidAnalogReport) {
  const auto report = HIDGamepadMakeReport(0, -32768, 32767, 123, -456, 0, 255);
  EXPECT_EQ(sizeof(report), 14u);
  EXPECT_EQ(report.reportId, 1);
  EXPECT_EQ(report.buttons, 0);
  EXPECT_EQ(report.hatSwitch, 8);
  EXPECT_EQ(report.leftStickX, -32768);
  EXPECT_EQ(report.leftStickY, 32767);
  EXPECT_EQ(report.rightStickX, 123);
  EXPECT_EQ(report.rightStickY, -456);
  EXPECT_EQ(report.leftTrigger, 0);
  EXPECT_EQ(report.rightTrigger, 255);
}

/**
 * @brief Map each protocol button independently without leaking d-pad or unknown bits.
 */
TEST(MacosGamepad, HidButtons) {
  const uint32_t buttons[] = {0x1000, 0x2000, 0x4000, 0x8000, 0x0100, 0x0200, 0x0020, 0x0010, 0x0040, 0x0080, 0x0400};
  for (unsigned i = 0; i < std::size(buttons); ++i) {
    EXPECT_EQ(HIDGamepadMakeReport(buttons[i], 0, 0, 0, 0, 0, 0).buttons, 1u << i);
  }
  EXPECT_EQ(HIDGamepadMakeReport(0xffffffff, 0, 0, 0, 0, 0, 0).buttons, 0x7ff);
  EXPECT_EQ(HIDGamepadMakeReport(0x080f, 0, 0, 0, 0, 0, 0).buttons, 0);
}

/**
 * @brief Map all eight d-pad directions and neutral to HID hat positions.
 */
TEST(MacosGamepad, HidHatDirections) {
  const uint32_t directions[] = {1, 9, 8, 10, 2, 6, 4, 5, 0};
  for (unsigned i = 0; i < std::size(directions); ++i) {
    EXPECT_EQ(HIDGamepadMakeReport(directions[i], 0, 0, 0, 0, 0, 0).hatSwitch, i);
  }
}

/**
 * @brief Intercept emulated events so disconnect can be tested without typing or clicking.
 */
@interface RecordingGamepad: MacOSGamepad
@property (nonatomic, assign) int keyDowns;  ///< Number of intercepted key presses.
@property (nonatomic, assign) int keyUps;  ///< Number of intercepted key releases.
@property (nonatomic, assign) int mouseDowns;  ///< Number of intercepted mouse presses.
@property (nonatomic, assign) int mouseUps;  ///< Number of intercepted mouse releases.
@end
@implementation RecordingGamepad

/** @brief Record a key press. @param keyCode Ignored key code. */
- (void)pressKey:(int)keyCode {
  self.keyDowns++;
}

/** @brief Record a key release. @param keyCode Ignored key code. */
- (void)releaseKey:(int)keyCode {
  self.keyUps++;
}

/** @brief Suppress pointer movement. @param deltaX Horizontal delta. @param deltaY Vertical delta. */
- (void)moveMouse:(float)deltaX deltaY:(float)deltaY {
}

/** @brief Record a mouse button transition. @param button Mouse button. @param pressed Press or release. */
- (void)mouseButton:(CGMouseButton)button pressed:(BOOL)pressed {
  if (pressed) {
    self.mouseDowns++;
  } else {
    self.mouseUps++;
  }
}

@end

/**
 * @brief Disconnect releases held keyboard and trigger buttons exactly once.
 */
TEST(MacosGamepad, EmulationDisconnectReleasesHeldInput) {
  auto *device = [[RecordingGamepad alloc] initWithIndex:0];
  ASSERT_NE(device, nil);
  [device updateState:0x1000 leftStickX:0 leftStickY:0 rightStickX:0 rightStickY:0 leftTrigger:255 rightTrigger:255];
  EXPECT_EQ(device.keyDowns, 1);
  EXPECT_EQ(device.mouseDowns, 2);
  [device disconnect];
  EXPECT_EQ(device.keyUps, 1);
  EXPECT_EQ(device.mouseUps, 2);
  EXPECT_FALSE(device.isConnected);
  [device disconnect];
  [device updateState:0x1000 leftStickX:0 leftStickY:0 rightStickX:0 rightStickY:0 leftTrigger:255 rightTrigger:255];
  EXPECT_EQ(device.keyDowns, 1);
  EXPECT_EQ(device.keyUps, 1);
  EXPECT_EQ(device.mouseUps, 2);
  [device release];
}

namespace {
  /**
   * @brief Intercept native device creation and state delivery to test platform routing.
   */
  class MacosGamepadRouting: public ::testing::Test {
  protected:
    static inline bool hid_available = true;  ///< Injected native creation result.
    static inline int hid_creations = 0;  ///< Native allocation attempts.
    static inline int hid_updates = 0;  ///< State updates routed to HID.
    static inline int emulated_updates = 0;  ///< State updates routed to emulation.
    Method create_method {};  ///< Native creation method.
    Method hid_update_method {};  ///< Native update method.
    Method emulated_update_method {};  ///< Emulated update method.
    IMP original_create {};  ///< Original native creation implementation.
    IMP original_hid_update {};  ///< Original HID update implementation.
    IMP original_emulated_update {};  ///< Original emulated update implementation.

    /**
     * @brief Simulate HID availability without requesting a system device.
     * @param object Controller object.
     * @param selector Invoked method.
     * @return Injected availability result.
     */
    static BOOL create(id object, SEL selector) {
      ++hid_creations;
      return hid_available;
    }

    /**
     * @brief Record native state delivery without sending an HID report.
     * @param object Controller object.
     * @param selector Invoked method.
     * @param buttons Client buttons.
     * @param lx Left stick X.
     * @param ly Left stick Y.
     * @param rx Right stick X.
     * @param ry Right stick Y.
     * @param lt Left trigger.
     * @param rt Right trigger.
     */
    static void update_hid(id object, SEL selector, uint32_t buttons, int16_t lx, int16_t ly, int16_t rx, int16_t ry, uint8_t lt, uint8_t rt) {
      ++hid_updates;
      EXPECT_EQ(buttons, 0x1000u);
      EXPECT_EQ(lt, 255);
    }

    /**
     * @brief Record emulated state delivery without posting keyboard or mouse events.
     * @param object Controller object.
     * @param selector Invoked method.
     * @param buttons Client buttons.
     * @param lx Left stick X.
     * @param ly Left stick Y.
     * @param rx Right stick X.
     * @param ry Right stick Y.
     * @param lt Left trigger.
     * @param rt Right trigger.
     */
    static void update_emulated(id object, SEL selector, uint16_t buttons, int16_t lx, int16_t ly, int16_t rx, int16_t ry, uint8_t lt, uint8_t rt) {
      ++emulated_updates;
    }

    /**
     * @brief Install device interception and reset counters.
     */
    void SetUp() override {
      hid_available = true;
      hid_creations = hid_updates = emulated_updates = 0;
      const auto update_selector = @selector(updateState:leftStickX:leftStickY:rightStickX:rightStickY:leftTrigger:rightTrigger:);
      create_method = class_getInstanceMethod([HIDGamepad class], @selector(createDevice));
      hid_update_method = class_getInstanceMethod([HIDGamepad class], update_selector);
      emulated_update_method = class_getInstanceMethod([MacOSGamepad class], update_selector);
      original_create = method_setImplementation(create_method, reinterpret_cast<IMP>(&create));
      original_hid_update = method_setImplementation(hid_update_method, reinterpret_cast<IMP>(&update_hid));
      original_emulated_update = method_setImplementation(emulated_update_method, reinterpret_cast<IMP>(&update_emulated));
    }

    /**
     * @brief Restore the native backend after all local devices have been released.
     */
    void TearDown() override {
      method_setImplementation(create_method, original_create);
      method_setImplementation(hid_update_method, original_hid_update);
      method_setImplementation(emulated_update_method, original_emulated_update);
    }
  };
}  // namespace

/**
 * @brief Native devices survive reconnect and reject duplicate allocation until released.
 */
TEST_F(MacosGamepadRouting, NativeControllerLifecycle) {
  auto input = platf::input();
  const platf::gamepad_id_t id {0, 0};
  EXPECT_EQ(platf::rebind_gamepad(input, id, nullptr), -1);
  ASSERT_EQ(platf::alloc_gamepad(input, id, {}, nullptr), 0);
  EXPECT_EQ(platf::alloc_gamepad(input, id, {}, nullptr), -1);
  EXPECT_EQ(hid_creations, 1);
  EXPECT_EQ(platf::rebind_gamepad(input, {0, 3}, nullptr), 0);
  platf::gamepad_update(input, 0, {0x1000, 255, 0, 0, 0, 0, 0});
  EXPECT_EQ(hid_updates, 1);
  EXPECT_EQ(emulated_updates, 0);
  platf::free_gamepad(input, 0);
  platf::gamepad_update(input, 0, {});
  EXPECT_EQ(hid_updates, 1);
  EXPECT_EQ(platf::rebind_gamepad(input, id, nullptr), -1);
  platf::free_gamepad(input, -1);
  platf::free_gamepad(input, platf::MAX_GAMEPADS);
}

/**
 * @brief Native creation failure routes updates to the keyboard/mouse compatibility device.
 */
TEST_F(MacosGamepadRouting, NativeFailureUsesEmulation) {
  hid_available = false;
  auto input = platf::input();
  ASSERT_EQ(platf::alloc_gamepad(input, {0, 0}, {}, nullptr), 0);
  EXPECT_EQ(hid_creations, 1);
  platf::gamepad_update(input, 0, {0x1000, 255, 0, 0, 0, 0, 0});
  EXPECT_EQ(hid_updates, 0);
  EXPECT_EQ(emulated_updates, 1);
  platf::free_gamepad(input, 0);
  EXPECT_EQ(emulated_updates, 2);  // The neutral state is delivered before disconnect.
  platf::free_gamepad(input, 0);
  EXPECT_EQ(emulated_updates, 2);
}
#endif
