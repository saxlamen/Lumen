# macos specific compile definitions

add_compile_definitions(SUNSHINE_PLATFORM="macos")

if (NOT SUNSHINE_BUILD_HOMEBREW)
    # Bundle layout for macOS app builds
    set(SUNSHINE_ASSETS_DIR "${CMAKE_PROJECT_NAME}.app/Contents/Resources/assets")
    set(SUNSHINE_ASSETS_DIR_DEF "../Resources/assets")
endif()

set(MACOS_LINK_DIRECTORIES
        /opt/homebrew/lib
        /opt/local/lib
        /usr/local/lib)

foreach(dir ${MACOS_LINK_DIRECTORIES})
    if(EXISTS ${dir})
        link_directories(${dir})
    endif()
endforeach()

if(NOT BOOST_USE_STATIC AND NOT FETCH_CONTENT_BOOST_USED)
    ADD_DEFINITIONS(-DBOOST_LOG_DYN_LINK)
endif()

# ScreenCaptureKit for system audio capture (macOS 12.3+)
FIND_LIBRARY(SCREEN_CAPTURE_KIT_LIBRARY ScreenCaptureKit)

list(APPEND SUNSHINE_EXTERNAL_LIBRARIES
        ${APP_KIT_LIBRARY}
        ${APP_SERVICES_LIBRARY}
        ${AUDIO_TOOLBOX_LIBRARY}
        ${AUDIO_UNIT_LIBRARY}
        ${AV_FOUNDATION_LIBRARY}
        ${CORE_AUDIO_LIBRARY}
        ${CORE_MEDIA_LIBRARY}
        ${CORE_VIDEO_LIBRARY}
        ${FOUNDATION_LIBRARY}
        ${IOKIT_LIBRARY}
        ${VIDEO_TOOLBOX_LIBRARY}
        ${SCREEN_CAPTURE_KIT_LIBRARY})

set(APPLE_PLIST_TEMPLATE "${SUNSHINE_SOURCE_ASSETS_DIR}/macos/build/Info.plist.in")
set(APPLE_PLIST_FILE "${CMAKE_BINARY_DIR}/Info.plist")
configure_file("${APPLE_PLIST_TEMPLATE}" "${APPLE_PLIST_FILE}" @ONLY)

set(PLATFORM_TARGET_FILES
        "${CMAKE_SOURCE_DIR}/src/platform/macos/av_audio.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/av_audio.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/av_img_t.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/av_video.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/av_video.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/sc_capture.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/sc_capture.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/sc_audio.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/sc_audio.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/virtual_display.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/virtual_display.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/display.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/input.cpp"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/smooth_scroll.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/smooth_scroll.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/microphone.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/misc.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/misc.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/nv12_zero_device.cpp"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/nv12_zero_device.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/publish.cpp"
        "${CMAKE_SOURCE_DIR}/third-party/TPCircularBuffer/TPCircularBuffer.c"
        "${CMAKE_SOURCE_DIR}/third-party/TPCircularBuffer/TPCircularBuffer.h"
        ${APPLE_PLIST_FILE})

# virtual_display.m uses ARC (required for CGVirtualDisplay private API lifecycle management)
set_source_files_properties(
        "${CMAKE_SOURCE_DIR}/src/platform/macos/virtual_display.m"
        PROPERTIES COMPILE_FLAGS "-fobjc-arc")

# Build vd_helper: standalone subprocess for creating CGVirtualDisplay
add_executable(vd_helper "${CMAKE_SOURCE_DIR}/src/platform/macos/vd_helper.m")
set_source_files_properties(
        "${CMAKE_SOURCE_DIR}/src/platform/macos/vd_helper.m"
        PROPERTIES COMPILE_FLAGS "-fobjc-arc")
target_link_libraries(vd_helper PRIVATE
        "-framework Foundation"
        "-framework AppKit"
        "-framework CoreGraphics"
        "-F/System/Library/PrivateFrameworks"
        "-framework SkyLight")
# Place vd_helper next to the sunshine binary
set_target_properties(vd_helper PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
