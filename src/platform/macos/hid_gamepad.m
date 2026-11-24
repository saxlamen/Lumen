/**
 * @file src/platform/macos/hid_gamepad.m
 * @brief Virtual HID gamepad implementation via IOHIDUserDevice.
 * @details Creates a virtual Xbox-style gamepad recognized by macOS Game Controller framework.
 *          Device creation is subject to macOS virtual HID permissions and entitlements.
 */
#import "hid_gamepad.h"

#import <IOKit/hidsystem/IOHIDUserDevice.h>
#import <mach/mach_time.h>

// Sunshine button flags (from platform/common.h)
#define SF_DPAD_UP 0x0001  ///< Dpad up input constant.
#define SF_DPAD_DOWN 0x0002  ///< Dpad down input constant.
#define SF_DPAD_LEFT 0x0004  ///< Dpad left input constant.
#define SF_DPAD_RIGHT 0x0008  ///< Dpad right input constant.
#define SF_START 0x0010  ///< Start input constant.
#define SF_BACK 0x0020  ///< Back input constant.
#define SF_LEFT_STICK 0x0040  ///< Left stick input constant.
#define SF_RIGHT_STICK 0x0080  ///< Right stick input constant.
#define SF_LEFT_BUTTON 0x0100  ///< Left button input constant.
#define SF_RIGHT_BUTTON 0x0200  ///< Right button input constant.
#define SF_HOME 0x0400  ///< Home input constant.
#define SF_A 0x1000  ///< A input constant.
#define SF_B 0x2000  ///< B input constant.
#define SF_X 0x4000  ///< X input constant.
#define SF_Y 0x8000  ///< Y input constant.

// Hat switch directions (matching HID spec 4-bit values)
#define HAT_N 0  ///< N input constant.
#define HAT_NE 1  ///< Ne input constant.
#define HAT_E 2  ///< E input constant.
#define HAT_SE 3  ///< Se input constant.
#define HAT_S 4  ///< S input constant.
#define HAT_SW 5  ///< Sw input constant.
#define HAT_W 6  ///< W input constant.
#define HAT_NW 7  ///< Nw input constant.
#define HAT_NONE 8  ///< None input constant.

/**
 * @brief HID Report Descriptor for an Xbox-style gamepad.
 *
 * Layout (Report ID 0x01, 13 bytes after report ID):
 *   - 16 buttons (2 bytes)
 *   - 1 hat switch, 4-bit + 4-bit padding (1 byte)
 *   - 2 triggers, 8-bit each (2 bytes)
 *   - 4 stick axes, 16-bit signed each (8 bytes)
 */
static const uint8_t kHIDReportDescriptor[] = {
  0x05,
  0x01,  // Usage Page (Generic Desktop)
  0x09,
  0x04,  // Usage (Joystick) — generic, avoids SDL's GCController-only path
  0xA1,
  0x01,  // Collection (Application)
  0x85,
  0x01,  //   Report ID (1)

  // --- 16 Buttons ---
  0x05,
  0x09,  //   Usage Page (Button)
  0x19,
  0x01,  //   Usage Minimum (1)
  0x29,
  0x10,  //   Usage Maximum (16)
  0x15,
  0x00,  //   Logical Minimum (0)
  0x25,
  0x01,  //   Logical Maximum (1)
  0x95,
  0x10,  //   Report Count (16)
  0x75,
  0x01,  //   Report Size (1)
  0x81,
  0x02,  //   Input (Data, Variable, Absolute)

  // --- Hat Switch (D-pad) ---
  0x05,
  0x01,  //   Usage Page (Generic Desktop)
  0x09,
  0x39,  //   Usage (Hat Switch)
  0x15,
  0x00,  //   Logical Minimum (0)
  0x25,
  0x07,  //   Logical Maximum (7)
  0x35,
  0x00,  //   Physical Minimum (0)
  0x46,
  0x3B,
  0x01,  //   Physical Maximum (315)
  0x65,
  0x14,  //   Unit (Degrees)
  0x75,
  0x04,  //   Report Size (4)
  0x95,
  0x01,  //   Report Count (1)
  0x81,
  0x42,  //   Input (Data, Variable, Absolute, Null State)

  // --- Hat Switch Padding (4 bits) ---
  0x75,
  0x04,  //   Report Size (4)
  0x95,
  0x01,  //   Report Count (1)
  0x81,
  0x01,  //   Input (Constant)

  // --- Triggers (2x 8-bit) ---
  0x05,
  0x02,  //   Usage Page (Simulation Controls)
  0x09,
  0xC5,  //   Usage (Brake) - Left Trigger
  0x09,
  0xC4,  //   Usage (Accelerator) - Right Trigger
  0x15,
  0x00,  //   Logical Minimum (0)
  0x26,
  0xFF,
  0x00,  //   Logical Maximum (255)
  0x75,
  0x08,  //   Report Size (8)
  0x95,
  0x02,  //   Report Count (2)
  0x81,
  0x02,  //   Input (Data, Variable, Absolute)

  // --- Stick Axes (4x 16-bit signed) ---
  0x05,
  0x01,  //   Usage Page (Generic Desktop)
  0x09,
  0x30,  //   Usage (X) - Left Stick X
  0x09,
  0x31,  //   Usage (Y) - Left Stick Y
  0x09,
  0x32,  //   Usage (Z) - Right Stick X
  0x09,
  0x35,  //   Usage (Rz) - Right Stick Y
  0x16,
  0x00,
  0x80,  //   Logical Minimum (-32768)
  0x26,
  0xFF,
  0x7F,  //   Logical Maximum (32767)
  0x75,
  0x10,  //   Report Size (16)
  0x95,
  0x04,  //   Report Count (4)
  0x81,
  0x02,  //   Input (Data, Variable, Absolute)

  0xC0  // End Collection
};

@implementation HIDGamepad

+ (BOOL)isAvailable {
  // Probe by attempting to create a minimal IOHIDUserDevice.
  // This will fail when SIP is enabled (entitlement check).
  NSDictionary *props = @{
    @kIOHIDVendorIDKey: @(0x1209),  // Generic (pid.codes open-source VID)
    @kIOHIDProductIDKey: @(0x5853),  // Not in SDL's known controller database
    @kIOHIDReportDescriptorKey: [NSData dataWithBytes:kHIDReportDescriptor
                                               length:sizeof(kHIDReportDescriptor)],
  };

  IOHIDUserDeviceRef testDevice = IOHIDUserDeviceCreateWithProperties(
    kCFAllocatorDefault,
    (__bridge CFDictionaryRef) props,
    0
  );

  if (testDevice) {
    CFRelease(testDevice);
    return YES;
  }

  return NO;
}

- (instancetype)initWithIndex:(int)index {
  self = [super init];
  if (self) {
    _gamepadIndex = index;
    _isConnected = NO;
    _hidDevice = NULL;
    _hidQueue = nil;
  }
  return self;
}

/**
 * @brief Dealloc for the macOS controller.
 */
- (void)dealloc {
  [self disconnect];
  [super dealloc];
}

- (BOOL)createDevice {
  if (_hidDevice) {
    return YES;
  }

  NSString *queueLabel = [NSString stringWithFormat:@"com.sunshine.hid.gamepad.%d", _gamepadIndex];
  dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
    DISPATCH_QUEUE_SERIAL,
    QOS_CLASS_USER_INTERACTIVE,
    0
  );
  _hidQueue = dispatch_queue_create([queueLabel UTF8String], attr);

  NSDictionary *props = @{
    @kIOHIDVendorIDKey: @(0x1209),  // Generic (pid.codes open-source VID)
    @kIOHIDProductIDKey: @(0x5853),  // Not in SDL's known controller database
    @kIOHIDManufacturerKey: @"Sunshine Virtual Gamepad",
    @kIOHIDProductKey: [NSString stringWithFormat:@"Sunshine Gamepad %d", _gamepadIndex],
    @kIOHIDSerialNumberKey: [NSString stringWithFormat:@"SUNSHINE-%d", _gamepadIndex],
    @kIOHIDTransportKey: @"USB",
    @kIOHIDReportDescriptorKey: [NSData dataWithBytes:kHIDReportDescriptor
                                               length:sizeof(kHIDReportDescriptor)],
  };

  _hidDevice = IOHIDUserDeviceCreateWithProperties(
    kCFAllocatorDefault,
    (__bridge CFDictionaryRef) props,
    0
  );

  if (!_hidDevice) {
    NSLog(@"[HIDGamepad] Failed to create IOHIDUserDevice for gamepad %d", _gamepadIndex);
    self.hidQueue = nil;
    return NO;
  }

  // Set up dispatch queue and activate the device
  IOHIDUserDeviceSetDispatchQueue(_hidDevice, _hidQueue);
  IOHIDUserDeviceActivate(_hidDevice);

  _isConnected = YES;

  // Send initial neutral state
  HIDGamepadReport report = {0};
  report.reportId = 0x01;
  report.hatSwitch = HAT_NONE;

  IOReturn result = IOHIDUserDeviceHandleReportWithTimeStamp(
    _hidDevice,
    mach_absolute_time(),
    (const uint8_t *) &report,
    sizeof(report)
  );
  if (result != kIOReturnSuccess) {
    NSLog(@"[HIDGamepad] Warning: failed to send initial report for gamepad %d (0x%x)", _gamepadIndex, result);
  }

  NSLog(@"[HIDGamepad] Gamepad %d created successfully (IOHIDUserDevice)", _gamepadIndex);
  return YES;
}

/**
 * @brief Converts Sunshine d-pad button flags to HID hat switch value.
 */
static uint8_t dpadToHatSwitch(uint32_t buttons) {
  BOOL up = (buttons & SF_DPAD_UP) != 0;
  BOOL down = (buttons & SF_DPAD_DOWN) != 0;
  BOOL left = (buttons & SF_DPAD_LEFT) != 0;
  BOOL right = (buttons & SF_DPAD_RIGHT) != 0;

  if (up && right) {
    return HAT_NE;
  }
  if (up && left) {
    return HAT_NW;
  }
  if (down && right) {
    return HAT_SE;
  }
  if (down && left) {
    return HAT_SW;
  }
  if (up) {
    return HAT_N;
  }
  if (right) {
    return HAT_E;
  }
  if (down) {
    return HAT_S;
  }
  if (left) {
    return HAT_W;
  }
  return HAT_NONE;
}

/**
 * @brief Maps Sunshine's 32-bit button flags to the 16-bit HID button field.
 *
 * HID button layout:
 *   bit 0: A       bit 4: LB       bit 8:  L3
 *   bit 1: B       bit 5: RB       bit 9:  R3
 *   bit 2: X       bit 6: Back     bit 10: Home
 *   bit 3: Y       bit 7: Start    bits 11-15: reserved
 */
static uint16_t mapButtons(uint32_t sf) {
  uint16_t hid = 0;
  if (sf & SF_A) {
    hid |= (1 << 0);
  }
  if (sf & SF_B) {
    hid |= (1 << 1);
  }
  if (sf & SF_X) {
    hid |= (1 << 2);
  }
  if (sf & SF_Y) {
    hid |= (1 << 3);
  }
  if (sf & SF_LEFT_BUTTON) {
    hid |= (1 << 4);
  }
  if (sf & SF_RIGHT_BUTTON) {
    hid |= (1 << 5);
  }
  if (sf & SF_BACK) {
    hid |= (1 << 6);
  }
  if (sf & SF_START) {
    hid |= (1 << 7);
  }
  if (sf & SF_LEFT_STICK) {
    hid |= (1 << 8);
  }
  if (sf & SF_RIGHT_STICK) {
    hid |= (1 << 9);
  }
  if (sf & SF_HOME) {
    hid |= (1 << 10);
  }
  return hid;
}

/**
 * @brief Convert a complete Moonlight state to the packed native HID report.
 * @param buttons Protocol button flags.
 * @param lsX Left stick horizontal position.
 * @param lsY Left stick vertical position.
 * @param rsX Right stick horizontal position.
 * @param rsY Right stick vertical position.
 * @param lt Left trigger pressure.
 * @param rt Right trigger pressure.
 * @return Report matching the native device descriptor.
 */
HIDGamepadReport HIDGamepadMakeReport(uint32_t buttons, int16_t lsX, int16_t lsY, int16_t rsX, int16_t rsY, uint8_t lt, uint8_t rt) {
  HIDGamepadReport report = {0};
  report.reportId = 0x01;
  report.buttons = mapButtons(buttons);
  report.hatSwitch = dpadToHatSwitch(buttons);
  report.leftTrigger = lt;
  report.rightTrigger = rt;
  report.leftStickX = lsX;
  report.leftStickY = lsY;
  report.rightStickX = rsX;
  report.rightStickY = rsY;

  return report;
}

- (void)updateState:(uint32_t)buttons
         leftStickX:(int16_t)lsX
         leftStickY:(int16_t)lsY
        rightStickX:(int16_t)rsX
        rightStickY:(int16_t)rsY
        leftTrigger:(uint8_t)lt
       rightTrigger:(uint8_t)rt {
  if (!_isConnected || !_hidDevice) {
    return;
  }

  HIDGamepadReport report = HIDGamepadMakeReport(buttons, lsX, lsY, rsX, rsY, lt, rt);

  IOReturn result = IOHIDUserDeviceHandleReportWithTimeStamp(
    _hidDevice,
    mach_absolute_time(),
    (const uint8_t *) &report,
    sizeof(report)
  );
  if (result != kIOReturnSuccess) {
    NSLog(@"[HIDGamepad] Failed to send report for gamepad %d (0x%x)", _gamepadIndex, result);
  }
}

- (void)disconnect {
  if (!_hidDevice) {
    return;
  }

  _isConnected = NO;

  IOHIDUserDeviceRef device = _hidDevice;
  dispatch_queue_t queue = _hidQueue;
  int index = _gamepadIndex;

  _hidDevice = NULL;

  if (queue) {
    // Cancel the device and release in the cancel handler
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    IOHIDUserDeviceSetCancelHandler(device, ^{
      CFRelease(device);
      dispatch_semaphore_signal(sem);
    });
    IOHIDUserDeviceCancel(device);
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    self.hidQueue = nil;
    dispatch_release(sem);
  } else {
    CFRelease(device);
  }

  NSLog(@"[HIDGamepad] Gamepad %d disconnected", index);
}

@end
