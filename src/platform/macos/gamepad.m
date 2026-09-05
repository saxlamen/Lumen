/**
 * @file src/platform/macos/gamepad.m
 * @brief Virtual gamepad implementation for macOS.
 * @details Emulates gamepad input via keyboard and mouse events.
 */
#import "gamepad.h"

// Gamepad button bit flags (matching Moonlight/Sunshine protocol)
#define BUTTON_DPAD_UP 0x0001  ///< Dpad up input constant.
#define BUTTON_DPAD_DOWN 0x0002  ///< Dpad down input constant.
#define BUTTON_DPAD_LEFT 0x0004  ///< Dpad left input constant.
#define BUTTON_DPAD_RIGHT 0x0008  ///< Dpad right input constant.
#define BUTTON_START 0x0010  ///< Start input constant.
#define BUTTON_BACK 0x0020  ///< Back input constant.
#define BUTTON_LEFT_STICK 0x0040  ///< Left stick input constant.
#define BUTTON_RIGHT_STICK 0x0080  ///< Right stick input constant.
#define BUTTON_LB 0x0100  ///< Lb input constant.
#define BUTTON_RB 0x0200  ///< Rb input constant.
#define BUTTON_HOME 0x0400  ///< Home input constant.
#define BUTTON_A 0x1000  ///< A input constant.
#define BUTTON_B 0x2000  ///< B input constant.
#define BUTTON_X 0x4000  ///< X input constant.
#define BUTTON_Y 0x8000  ///< Y input constant.

@implementation MacOSGamepad

+ (BOOL)isAvailable {
  // Keyboard/mouse emulation is always available
  return YES;
}

- (instancetype)initWithIndex:(int)index {
  self = [super init];
  if (self) {
    self.gamepadIndex = index;
    self.isConnected = YES;
    self.keyMapping = kDefaultGamepadMapping;
    self.leftStickDeadzone = 0.15f;
    self.rightStickDeadzone = 0.15f;
    self.mouseSensitivity = 15.0f;
    self.buttonState = 0;
    self.leftStickX = 0;
    self.leftStickY = 0;
    self.rightStickX = 0;
    self.rightStickY = 0;
    self.leftTrigger = 0;
    self.rightTrigger = 0;

    self.eventSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (!self.eventSource) {
      self.isConnected = NO;
      [self release];
      return nil;
    }

    NSLog(@"[MacOSGamepad] Gamepad %d connected (keyboard/mouse emulation mode)", index);
  }
  return self;
}

/**
 * @brief Dealloc for the macOS controller.
 */
- (void)dealloc {
  [self disconnect];
  if (self.eventSource) {
    CFRelease(self.eventSource);
  }
  [super dealloc];
}

- (void)disconnect {
  if (!self.isConnected) {
    return;
  }
  [self updateState:0 leftStickX:0 leftStickY:0 rightStickX:0 rightStickY:0 leftTrigger:0 rightTrigger:0];
  self.isConnected = NO;
  NSLog(@"[MacOSGamepad] Gamepad %d disconnected", self.gamepadIndex);
}

/**
 * @brief Normalize stick value for the macOS controller.
 * @param value Value.
 * @return Result of the controller operation.
 */
- (float)normalizeStickValue:(int16_t)value {
  // Normalize from -32768..32767 to -1.0..1.0
  return (float) value / 32767.0f;
}

/**
 * @brief Press key for the macOS controller.
 * @param keyCode Key code.
 */
- (void)pressKey:(int)keyCode {
  CGEventRef keyDown = CGEventCreateKeyboardEvent(self.eventSource, keyCode, true);
  CGEventPost(kCGHIDEventTap, keyDown);
  CFRelease(keyDown);
}

/**
 * @brief Release key for the macOS controller.
 * @param keyCode Key code.
 */
- (void)releaseKey:(int)keyCode {
  CGEventRef keyUp = CGEventCreateKeyboardEvent(self.eventSource, keyCode, false);
  CGEventPost(kCGHIDEventTap, keyUp);
  CFRelease(keyUp);
}

/**
 * @brief Handle button change for the macOS controller.
 * @param buttonMask Button mask.
 * @param keyCode Key code.
 * @param wasPressed Was pressed.
 * @param isPressed Is pressed.
 */
- (void)handleButtonChange:(uint16_t)buttonMask keyCode:(int)keyCode wasPressed:(BOOL)wasPressed isPressed:(BOOL)isPressed {
  if (isPressed && !wasPressed) {
    [self pressKey:keyCode];
  } else if (!isPressed && wasPressed) {
    [self releaseKey:keyCode];
  }
}

/**
 * @brief Move mouse for the macOS controller.
 * @param deltaX Delta x.
 * @param deltaY Delta y.
 */
- (void)moveMouse:(float)deltaX deltaY:(float)deltaY {
  if (fabs(deltaX) < 0.01f && fabs(deltaY) < 0.01f) {
    return;
  }

  CGEventRef moveEvent = CGEventCreateMouseEvent(
    self.eventSource,
    kCGEventMouseMoved,
    CGPointZero,
    kCGMouseButtonLeft
  );

  // Set relative movement
  CGEventSetIntegerValueField(moveEvent, kCGMouseEventDeltaX, (int) (deltaX * self.mouseSensitivity));
  CGEventSetIntegerValueField(moveEvent, kCGMouseEventDeltaY, (int) (deltaY * self.mouseSensitivity));

  CGEventPost(kCGHIDEventTap, moveEvent);
  CFRelease(moveEvent);
}

/**
 * @brief Mouse button for the macOS controller.
 * @param button Button.
 * @param pressed Pressed.
 */
- (void)mouseButton:(CGMouseButton)button pressed:(BOOL)pressed {
  CGEventType eventType;

  if (button == kCGMouseButtonLeft) {
    eventType = pressed ? kCGEventLeftMouseDown : kCGEventLeftMouseUp;
  } else if (button == kCGMouseButtonRight) {
    eventType = pressed ? kCGEventRightMouseDown : kCGEventRightMouseUp;
  } else {
    eventType = pressed ? kCGEventOtherMouseDown : kCGEventOtherMouseUp;
  }

  // Get current mouse position
  CGEventRef posEvent = CGEventCreate(self.eventSource);
  CGPoint mousePos = CGEventGetLocation(posEvent);
  CFRelease(posEvent);

  CGEventRef clickEvent = CGEventCreateMouseEvent(
    self.eventSource,
    eventType,
    mousePos,
    button
  );

  CGEventPost(kCGHIDEventTap, clickEvent);
  CFRelease(clickEvent);
}

- (void)updateState:(uint16_t)buttons
         leftStickX:(int16_t)lsX
         leftStickY:(int16_t)lsY
        rightStickX:(int16_t)rsX
        rightStickY:(int16_t)rsY
        leftTrigger:(uint8_t)lt
       rightTrigger:(uint8_t)rt {
  if (!self.isConnected) {
    return;
  }

  uint16_t oldButtons = self.buttonState;

  // Handle button presses
  [self handleButtonChange:BUTTON_A
                   keyCode:self.keyMapping.a_key
                wasPressed:(oldButtons & BUTTON_A)
                 isPressed:(buttons & BUTTON_A)];
  [self handleButtonChange:BUTTON_B
                   keyCode:self.keyMapping.b_key
                wasPressed:(oldButtons & BUTTON_B)
                 isPressed:(buttons & BUTTON_B)];
  [self handleButtonChange:BUTTON_X
                   keyCode:self.keyMapping.x_key
                wasPressed:(oldButtons & BUTTON_X)
                 isPressed:(buttons & BUTTON_X)];
  [self handleButtonChange:BUTTON_Y
                   keyCode:self.keyMapping.y_key
                wasPressed:(oldButtons & BUTTON_Y)
                 isPressed:(buttons & BUTTON_Y)];
  [self handleButtonChange:BUTTON_LB
                   keyCode:self.keyMapping.lb_key
                wasPressed:(oldButtons & BUTTON_LB)
                 isPressed:(buttons & BUTTON_LB)];
  [self handleButtonChange:BUTTON_RB
                   keyCode:self.keyMapping.rb_key
                wasPressed:(oldButtons & BUTTON_RB)
                 isPressed:(buttons & BUTTON_RB)];
  [self handleButtonChange:BUTTON_START
                   keyCode:self.keyMapping.start_key
                wasPressed:(oldButtons & BUTTON_START)
                 isPressed:(buttons & BUTTON_START)];
  [self handleButtonChange:BUTTON_BACK
                   keyCode:self.keyMapping.back_key
                wasPressed:(oldButtons & BUTTON_BACK)
                 isPressed:(buttons & BUTTON_BACK)];
  [self handleButtonChange:BUTTON_LEFT_STICK
                   keyCode:self.keyMapping.lstick_key
                wasPressed:(oldButtons & BUTTON_LEFT_STICK)
                 isPressed:(buttons & BUTTON_LEFT_STICK)];
  [self handleButtonChange:BUTTON_RIGHT_STICK
                   keyCode:self.keyMapping.rstick_key
                wasPressed:(oldButtons & BUTTON_RIGHT_STICK)
                 isPressed:(buttons & BUTTON_RIGHT_STICK)];

  // D-pad
  [self handleButtonChange:BUTTON_DPAD_UP
                   keyCode:self.keyMapping.dpad_up_key
                wasPressed:(oldButtons & BUTTON_DPAD_UP)
                 isPressed:(buttons & BUTTON_DPAD_UP)];
  [self handleButtonChange:BUTTON_DPAD_DOWN
                   keyCode:self.keyMapping.dpad_down_key
                wasPressed:(oldButtons & BUTTON_DPAD_DOWN)
                 isPressed:(buttons & BUTTON_DPAD_DOWN)];
  [self handleButtonChange:BUTTON_DPAD_LEFT
                   keyCode:self.keyMapping.dpad_left_key
                wasPressed:(oldButtons & BUTTON_DPAD_LEFT)
                 isPressed:(buttons & BUTTON_DPAD_LEFT)];
  [self handleButtonChange:BUTTON_DPAD_RIGHT
                   keyCode:self.keyMapping.dpad_right_key
                wasPressed:(oldButtons & BUTTON_DPAD_RIGHT)
                 isPressed:(buttons & BUTTON_DPAD_RIGHT)];

  self.buttonState = buttons;

  // Handle left stick -> mouse movement
  float leftX = [self normalizeStickValue:lsX];
  float leftY = [self normalizeStickValue:lsY];

  if (fabs(leftX) > self.leftStickDeadzone || fabs(leftY) > self.leftStickDeadzone) {
    // Apply deadzone
    if (fabs(leftX) <= self.leftStickDeadzone) {
      leftX = 0;
    }
    if (fabs(leftY) <= self.leftStickDeadzone) {
      leftY = 0;
    }

    [self moveMouse:leftX deltaY:leftY];
  }

  self.leftStickX = lsX;
  self.leftStickY = lsY;
  self.rightStickX = rsX;
  self.rightStickY = rsY;

  // Handle triggers -> mouse buttons
  // Left trigger = right click, Right trigger = left click
  BOOL ltPressed = lt > 127;
  BOOL rtPressed = rt > 127;
  BOOL wasLtPressed = self.leftTrigger > 127;
  BOOL wasRtPressed = self.rightTrigger > 127;

  if (ltPressed != wasLtPressed) {
    [self mouseButton:kCGMouseButtonRight pressed:ltPressed];
  }
  if (rtPressed != wasRtPressed) {
    [self mouseButton:kCGMouseButtonLeft pressed:rtPressed];
  }

  self.leftTrigger = lt;
  self.rightTrigger = rt;
}

@end
