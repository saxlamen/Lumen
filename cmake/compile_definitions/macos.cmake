# macos specific compile definitions

add_compile_definitions(SUNSHINE_PLATFORM="macos")

if (SUNSHINE_BUILD_HOMEBREW)
    set(SUNSHINE_ASSETS_DIR "${CMAKE_INSTALL_PREFIX}/${SUNSHINE_ASSETS_DIR}")
else()
    # Bundle layout for macOS app builds
    set(SUNSHINE_ASSETS_DIR ".Lumax/Lumax.app/Contents/Resources/assets")
    set(SUNSHINE_ASSETS_DIR_DEF "../Resources/assets")
endif()
set(MACOS_APP_NAME "Lumax")

set(MACOS_LINK_DIRECTORIES
        /opt/homebrew/lib
        /opt/local/lib
        /usr/local/lib)

foreach(dir ${MACOS_LINK_DIRECTORIES})
    if(EXISTS ${dir})
        link_directories(${dir})
    endif()
endforeach()

if(NOT BOOST_USE_STATIC AND NOT CPM_BOOST_USED)
    ADD_DEFINITIONS(-DBOOST_LOG_DYN_LINK)
endif()

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
        ${USER_NOTIFICATIONS_LIBRARY}
        ${SCREEN_CAPTURE_KIT_LIBRARY}
        ${VIDEO_TOOLBOX_LIBRARY}
        "-framework ServiceManagement")

set(APPLE_PLIST_TEMPLATE "${SUNSHINE_SOURCE_ASSETS_DIR}/macos/build/Info.plist.in")
set(APPLE_PLIST_FILE "${CMAKE_BINARY_DIR}/Info.plist")
set(APPLE_ENTITLEMENTS_FILE "${SUNSHINE_SOURCE_ASSETS_DIR}/macos/entitlements.plist")
configure_file("${APPLE_PLIST_TEMPLATE}" "${APPLE_PLIST_FILE}" @ONLY)

set(PLATFORM_TARGET_FILES
        "${CMAKE_SOURCE_DIR}/src/platform/macos/av_audio.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/av_audio.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/av_img_t.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/av_video.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/av_video.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/display.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/display_helpers.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/display_helpers.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/hdr_capture.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/input.cpp"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/gamepad.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/hid_gamepad.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/gamepad_bridge.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/microphone.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/misc.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/misc.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/permissions.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/permissions.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/publish.cpp"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/sc_capture.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/sc_capture.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/sc_capture_loop.cpp"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/sc_capture_loop.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/smooth_scroll.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/smooth_scroll.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/vt_encoder.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/vt_encoder.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/virtual_display.h"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/virtual_display.m"
        "${tpcircularbuffer_SOURCE_DIR}/TPCircularBuffer.c"
        "${tpcircularbuffer_SOURCE_DIR}/TPCircularBuffer.h"
        ${APPLE_ENTITLEMENTS_FILE}
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
set_target_properties(vd_helper PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
