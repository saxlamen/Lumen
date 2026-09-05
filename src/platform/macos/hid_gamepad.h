/**
 * @file src/platform/macos/hid_gamepad.h
 * @brief Virtual HID gamepad via IOHIDUserDevice for macOS.
 * @details Creates a system-wide virtual gamepad that macOS Game Controller
 *          framework recognizes when macOS permits virtual HID creation.
 */
#pragma once

#import <Foundation/Foundation.h>
#import <IOKit/hidsystem/IOHIDUserDevice.h>

/**
 * @brief HID report sent to IOHIDUserDevice. Packed to exactly 14 bytes.
 * Matches the HID report descriptor defined in hid_gamepad.m.
 */
typedef struct __attribute__((packed)) {
  uint8_t reportId;  ///< Always 0x01
  uint16_t buttons;  ///< 16 button bits
  uint8_t hatSwitch;  ///< D-pad hat switch (0-7 = directions, 8 = neutral)
  uint8_t leftTrigger;  ///< 0-255
  uint8_t rightTrigger;  ///< 0-255
  int16_t leftStickX;  ///< -32768 to 32767
  int16_t leftStickY;  ///< -32768 to 32767
  int16_t rightStickX;  ///< -32768 to 32767
  int16_t rightStickY;  ///< -32768 to 32767
} HIDGamepadReport;  ///< Packed native controller report.

#ifdef __cplusplus
extern "C" {
#endif
  /**
   * @brief Build a native HID report without creating a system device.
   * @param buttons Protocol button flags.
   * @param lsX Left stick horizontal position.
   * @param lsY Left stick vertical position.
   * @param rsX Right stick horizontal position.
   * @param rsY Right stick vertical position.
   * @param lt Left trigger pressure.
   * @param rt Right trigger pressure.
   * @return Packed report matching the HID descriptor.
   */
  HIDGamepadReport HIDGamepadMakeReport(uint32_t buttons, int16_t lsX, int16_t lsY, int16_t rsX, int16_t rsY, uint8_t lt, uint8_t rt);
#ifdef __cplusplus
}
#endif

/**
 * @brief Native Xbox-style virtual HID controller.
 */
@interface HIDGamepad: NSObject

@property (nonatomic, assign) int gamepadIndex;  ///< Gamepad index.
@property (nonatomic, assign) BOOL isConnected;  ///< Is connected.
@property (nonatomic, assign) IOHIDUserDeviceRef hidDevice;  ///< Hid device.
@property (nonatomic, strong) dispatch_queue_t hidQueue;  ///< Hid queue.

/**
 * @brief Probes whether IOHIDUserDevice virtual gamepads can be created.
 * Returns NO when SIP is enabled (device creation fails).
 */
+ (BOOL)isAvailable;

/**
 * @brief Init with index for the macOS controller.
 * @param index Index.
 * @return Result of the controller operation.
 */
- (instancetype)initWithIndex:(int)index;

/**
 * @brief Creates the IOHIDUserDevice and sends an initial neutral-state report.
 * @return YES on success, NO on failure.
 */
- (BOOL)createDevice;

/**
 * @brief Maps Sunshine's gamepad state to an HID report and sends it.
 * @param buttons  Sunshine's 32-bit buttonFlags (only lower 16 bits + HOME used)
 * @param lsX      Left stick X (-32768..32767)
 * @param lsY      Left stick Y (-32768..32767)
 * @param rsX      Right stick X (-32768..32767)
 * @param rsY      Right stick Y (-32768..32767)
 * @param lt       Left trigger (0..255)
 * @param rt       Right trigger (0..255)
 */
- (void)updateState:(uint32_t)buttons
         leftStickX:(int16_t)lsX
         leftStickY:(int16_t)lsY
        rightStickX:(int16_t)rsX
        rightStickY:(int16_t)rsY
        leftTrigger:(uint8_t)lt
       rightTrigger:(uint8_t)rt;

/**
 * @brief Destroys the IOHIDUserDevice and cleans up resources.
 */
- (void)disconnect;

@end
