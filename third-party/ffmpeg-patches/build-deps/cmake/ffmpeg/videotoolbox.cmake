# Pure source patch component: unlike x264.cmake or svt_av1.cmake there is no library to build,
# only patches to apply to the generated FFmpeg source tree before ffmpeg.cmake configures it.
if(BUILD_FFMPEG_ALL_PATCHES OR BUILD_FFMPEG_VIDEOTOOLBOX_PATCHES)
    file(GLOB FFMPEG_VIDEOTOOLBOX_PATCH_FILES ${CMAKE_CURRENT_SOURCE_DIR}/patches/FFmpeg/FFmpeg/videotoolbox/*.patch)

    foreach(patch_file ${FFMPEG_VIDEOTOOLBOX_PATCH_FILES})
        APPLY_GIT_PATCH(${FFMPEG_GENERATED_SRC_PATH} ${patch_file})
    endforeach()
endif()
