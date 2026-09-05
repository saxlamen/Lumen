/**
 * @file src/platform/macos/gamepad.h
 * @brief Virtual gamepad support for macOS.
 * @details Provides gamepad input emulation via:
 *   - Keyboard/Mouse emulation (default, no drivers needed)
 */
#pragma once

#import <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

/**
 * @brief Keyboard bindings for controller buttons.
 */
typedef struct {
  int a_key;  ///< A button -> key
  int b_key;  ///< B button -> key
  int x_key;  ///< X button -> key
  int y_key;  ///< Y button -> key
  int lb_key;  ///< Left bumper -> key
  int rb_key;  ///< Right bumper -> key
  int start_key;  ///< Start -> key
  int back_key;  ///< Back/Select -> key
  int lstick_key;  ///< Left stick click -> key
  int rstick_key;  ///< Right stick click -> key
  int dpad_up_key;  ///< D-pad up -> key
  int dpad_down_key;  ///< D-pad down -> key
  int dpad_left_key;  ///< D-pad left -> key
  int dpad_right_key;  ///< D-pad right -> key
} GamepadKeyMapping;

/**
 * @brief Default keyboard bindings retained from main.
 */
static const GamepadKeyMapping kDefaultGamepadMapping = {
  .a_key = kVK_Space,  // A -> Space (jump/action)
  .b_key = kVK_ANSI_E,  // B -> E (interact)
  .x_key = kVK_ANSI_R,  // X -> R (reload)
  .y_key = kVK_ANSI_F,  // Y -> F (use)
  .lb_key = kVK_ANSI_Q,  // LB -> Q
  .rb_key = kVK_Tab,  // RB -> Tab
  .start_key = kVK_Escape,  // Start -> Escape
  .back_key = kVK_Tab,  // Back -> Tab
  .lstick_key = kVK_Shift,  // L3 -> Shift (sprint)
  .rstick_key = kVK_ANSI_V,  // R3 -> V (melee)
  .dpad_up_key = kVK_ANSI_1,  // D-pad -> number keys (weapon select)
  .dpad_down_key = kVK_ANSI_3,
  .dpad_left_key = kVK_ANSI_4,
  .dpad_right_key = kVK_ANSI_2,
};

/**
 * @brief Controller compatibility mode using keyboard and mouse events.
 */
@interface MacOSGamepad: NSObject

@property (nonatomic, assign) int gamepadIndex;  ///< Gamepad index.
@property (nonatomic, assign) BOOL isConnected;  ///< Is connected.
@property (nonatomic, assign) GamepadKeyMapping keyMapping;  ///< Key mapping.
@property (nonatomic, assign) float leftStickDeadzone;  ///< Left stick deadzone.
@property (nonatomic, assign) float rightStickDeadzone;  ///< Right stick deadzone.
@property (nonatomic, assign) float mouseSensitivity;  ///< Mouse sensitivity.
@property (nonatomic, assign) CGEventSourceRef eventSource;  ///< Event source.

// Button state tracking
@property (nonatomic, assign) uint16_t buttonState;  ///< Button state.
@property (nonatomic, assign) int16_t leftStickX;  ///< Left stick x.
@property (nonatomic, assign) int16_t leftStickY;  ///< Left stick y.
@property (nonatomic, assign) int16_t rightStickX;  ///< Right stick x.
@property (nonatomic, assign) int16_t rightStickY;  ///< Right stick y.
@property (nonatomic, assign) uint8_t leftTrigger;  ///< Left trigger.
@property (nonatomic, assign) uint8_t rightTrigger;  ///< Right trigger.

/**
 * @brief Is available for the macOS controller.
 * @return Result of the controller operation.
 */
+ (BOOL)isAvailable;

/**
 * @brief Init with index for the macOS controller.
 * @param index Index.
 * @return Result of the controller operation.
 */
- (instancetype)initWithIndex:(int)index;
/**
 * @brief Update state for the macOS controller.
 * @param buttons Buttons.
 * @param lsX Ls x.
 * @param lsY Ls y.
 * @param rsX Rs x.
 * @param rsY Rs y.
 * @param lt Lt.
 * @param rt Rt.
 */
- (void)updateState:(uint16_t)buttons
         leftStickX:(int16_t)lsX
         leftStickY:(int16_t)lsY
        rightStickX:(int16_t)rsX
        rightStickY:(int16_t)rsY
        leftTrigger:(uint8_t)lt
       rightTrigger:(uint8_t)rt;
/**
 * @brief Disconnect for the macOS controller.
 */
- (void)disconnect;

@end
