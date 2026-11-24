# macos specific target definitions

if (SUNSHINE_BUILD_HOMEBREW)
    target_link_options(lumen PRIVATE LINKER:-sectcreate,__TEXT,__info_plist,${APPLE_PLIST_FILE})
else()
    # .app build
    set_target_properties(lumen PROPERTIES
            OUTPUT_NAME "Lumax"
            MACOSX_BUNDLE_BUNDLE_NAME "Lumax"
            MACOSX_BUNDLE_GUI_IDENTIFIER "${PROJECT_FQDN}"
            MACOSX_BUNDLE_INFO_PLIST "${APPLE_PLIST_FILE}"
            MACOSX_BUNDLE_ICON_FILE "sunshine.icns"
            MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
            MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}")

    # Populate bundle resources in the build tree for local runs.
    #
    # This is a second copy of the vite output, and CPack later installs the bundle directory and
    # assets/web separately, in two passes. Without an ordering the copy below can run before vite
    # finishes, leaving the bundle holding stale web assets: pass one seals the codesign resources
    # over one of the two copies, and pass two replaces it with the other because the source now
    # looks newer, which notarization rejects as "the signature of the binary is invalid" on the
    # main executable while codesign --verify passes, because the seal was fine when it was made.
    # Unsigned builds never notice, since there is no seal to break.
    add_dependencies(lumen web-ui)
    set(_bundle_resources_dir "$<TARGET_FILE_DIR:lumen>/../Resources")
    add_custom_command(TARGET lumen POST_BUILD
            COMMENT "Copying bundle resources to build tree"
            COMMAND "${CMAKE_COMMAND}" -E make_directory "${_bundle_resources_dir}"
            COMMAND "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_BINARY_DIR}/assets" "${_bundle_resources_dir}/assets"
            VERBATIM)
endif()

# Tell linker to dynamically load these symbols at runtime, in case they're unavailable:
target_link_options(lumen PRIVATE -Wl,-U,_CGPreflightScreenCaptureAccess -Wl,-U,_CGRequestScreenCaptureAccess)

# Keep the display helper beside the executable for both CLI and bundle builds.
add_dependencies(lumen vd_helper)
if (NOT SUNSHINE_BUILD_HOMEBREW)
    add_custom_command(TARGET lumen POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                    "$<TARGET_FILE:vd_helper>" "$<TARGET_FILE_DIR:lumen>/vd_helper"
            COMMENT "Copying virtual display helper into the app bundle"
            VERBATIM)

    # Native DMG installer app ("Install Lumax.app")
    set(INSTALLER_PLIST_FILE "${CMAKE_BINARY_DIR}/InstallLumax.Info.plist")
    configure_file(
            "${PROJECT_SOURCE_DIR}/src_assets/macos/installer/Info.plist.in"
            "${INSTALLER_PLIST_FILE}"
            @ONLY)
    add_executable(install_lumax MACOSX_BUNDLE
            "${PROJECT_SOURCE_DIR}/src_assets/macos/installer/install_lumax.mm")
    set_target_properties(install_lumax PROPERTIES
            OUTPUT_NAME "Install ${MACOS_APP_NAME}"
            MACOSX_BUNDLE_BUNDLE_NAME "Install ${MACOS_APP_NAME}"
            MACOSX_BUNDLE_GUI_IDENTIFIER "${PROJECT_FQDN}.installer"
            MACOSX_BUNDLE_INFO_PLIST "${INSTALLER_PLIST_FILE}"
            MACOSX_BUNDLE_ICON_FILE "sunshine.icns"
            MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
            MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}")
    target_compile_definitions(install_lumax PRIVATE PROJECT_FQDN="${PROJECT_FQDN}")
    target_compile_options(install_lumax PRIVATE -fobjc-arc)
    target_link_libraries(install_lumax PRIVATE "-framework Cocoa")
endif()
