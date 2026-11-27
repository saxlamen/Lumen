# macos specific packaging

if (SUNSHINE_BUILD_HOMEBREW)
    install(DIRECTORY "${SUNSHINE_SOURCE_ASSETS_DIR}/macos/assets/"
            DESTINATION "${SUNSHINE_ASSETS_DIR}")

    # copy assets to build directory, for running without install
    file(COPY "${SUNSHINE_SOURCE_ASSETS_DIR}/macos/assets/"
         DESTINATION "${CMAKE_BINARY_DIR}/assets")
else()
    # .app build
    set(APPLE_CODESIGN_IDENTITY "" CACHE STRING "Codesign identity, e.g. 'Developer ID Application: Name (TEAMID)'")

    # Build an .app
    set(CMAKE_MACOSX_BUNDLE YES)

    set(MAC_PAYLOAD_DIR ".Lumax")
    set(MAC_BUNDLE_NAME "Lumax.app")
    set(MAC_BUNDLE_PATH "${MAC_PAYLOAD_DIR}/${MAC_BUNDLE_NAME}")
    set(MAC_BUNDLE_CONTENTS "${MAC_BUNDLE_PATH}/Contents")
    set(MAC_BUNDLE_RESOURCES "${MAC_BUNDLE_CONTENTS}/Resources")

    set(INSTALLER_BUNDLE_NAME "Install Lumax.app")
    set(INSTALLER_BUNDLE_RESOURCES "${INSTALLER_BUNDLE_NAME}/Contents/Resources")

    install(TARGETS install_lumax
        BUNDLE DESTINATION .
        COMPONENT Runtime)

    install(FILES "${PROJECT_SOURCE_DIR}/src_assets/macos/build/sunshine.icns"
            DESTINATION "${INSTALLER_BUNDLE_RESOURCES}"
            COMPONENT Runtime)

    install(TARGETS vd_helper
        RUNTIME DESTINATION "${MAC_BUNDLE_CONTENTS}/MacOS"
        COMPONENT Runtime)

    install(TARGETS sunshine
        BUNDLE DESTINATION "${MAC_PAYLOAD_DIR}"
        COMPONENT Runtime)

    install(FILES "${APPLE_PLIST_FILE}"
            DESTINATION "${MAC_BUNDLE_CONTENTS}"
            COMPONENT Runtime)

    install(FILES "${PROJECT_SOURCE_DIR}/src_assets/macos/build/sunshine.icns"
            DESTINATION "${MAC_BUNDLE_RESOURCES}"
            COMPONENT Runtime)

    # macOS-specific assets (apps.json, etc.)
    install(DIRECTORY "${SUNSHINE_SOURCE_ASSETS_DIR}/macos/assets/"
            DESTINATION "${MAC_BUNDLE_RESOURCES}/assets"
            COMPONENT Runtime
            PATTERN ".DS_Store" EXCLUDE
            PATTERN "._*" EXCLUDE)

    # Pull in non-system dylibs for a self-contained .app
    install(CODE "
        set(_app \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${MAC_BUNDLE_PATH}\")
        set(_installer \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${INSTALLER_BUNDLE_NAME}\")

        message(STATUS \"Running fixup_bundle for: \${_app}\")
        include(BundleUtilities)
        set(BU_CHMOD_BUNDLE_ITEMS TRUE)

        # Resolve @rpath items that Qt already deployed into the app bundle.
        function(gp_resolve_item_override context item exepath dirs resolved_item_var resolved_var)
          if(\"\${item}\" MATCHES \"^@rpath/(.+)$\")
            set(_embedded_item \"\${_app}/Contents/Frameworks/\${CMAKE_MATCH_1}\")
            if(EXISTS \"\${_embedded_item}\")
              set(\${resolved_item_var} \"\${_embedded_item}\" PARENT_SCOPE)
              set(\${resolved_var} TRUE PARENT_SCOPE)
            endif()
          endif()
        endfunction()

        fixup_bundle(\"\${_app}\" \"\" \"\")

        # Remove Finder/resource-fork metadata that breaks codesign.
        execute_process(COMMAND /usr/bin/xattr -rc \"\${_app}\")
        execute_process(COMMAND /usr/bin/xattr -rc \"\${_installer}\")

        message(STATUS \"removing any existing signatures\")
        execute_process(COMMAND /usr/bin/codesign
            --remove-signature --force --deep
            \"\${_app}\"
            RESULT_VARIABLE rc
        )
        if(NOT rc EQUAL 0)
            message(FATAL_ERROR \"codesign failed to remove existing signatures\")
        endif()
        execute_process(COMMAND /usr/bin/codesign
            --remove-signature --force --deep
            \"\${_installer}\"
            RESULT_VARIABLE installer_rm_rc
        )
        if(NOT installer_rm_rc EQUAL 0)
            message(FATAL_ERROR \"codesign failed to remove existing installer signatures\")
        endif()

        # SHOULD_SIGN is set only when publish_release is true or when manually building
        if(\"\$ENV{SHOULD_SIGN}\" STREQUAL \"true\")
          # Sign bundled frameworks and plugins before signing the app itself.
          set(_fw_dir \"\${_app}/Contents/Frameworks\")
          if(EXISTS \"\${_fw_dir}\")
              # Framework bundles are top-level directories.
              file(GLOB _framework_items
                  LIST_DIRECTORIES true
                  \"\${_fw_dir}/*.framework\"
              )
              # Recursively collect only library files.
              file(GLOB_RECURSE _sign_items
                  \"\${_fw_dir}/*.dylib\"
                  \"\${_app}/Contents/PlugIns/*.dylib\"
              )
              list(APPEND _sign_items \${_framework_items})

              foreach(item IN LISTS _sign_items)
                  execute_process(COMMAND /usr/bin/codesign --verbose=2
                      --sign \"${APPLE_CODESIGN_IDENTITY}\" \"\${item}\"
                      --force --timestamp --options=runtime
                      RESULT_VARIABLE rc2
                  )
                  if(NOT rc2 EQUAL 0)
                      message(FATAL_ERROR \"codesign failed while signing library: \${item}\")
                  endif()
              endforeach()
          endif()

          # Sign the nested helper before sealing the app bundle.
          execute_process(COMMAND /usr/bin/codesign --verbose=2
              --sign \"${APPLE_CODESIGN_IDENTITY}\" \"\${_app}/Contents/MacOS/vd_helper\"
              --force --timestamp --options=runtime
              RESULT_VARIABLE helper_rc
          )
          if(NOT helper_rc EQUAL 0)
              message(FATAL_ERROR \"codesign failed while signing vd_helper\")
          endif()

          # Embed provisioning profile and virtual HID entitlements when a matching local profile is present.
          set(_selected_entitlements \"${APPLE_ENTITLEMENTS_FILE}\")
          set(_profile_src \"\$ENV{APPLE_PROVISION_PROFILE}\")
          if(NOT _profile_src)
              set(_profile_src \"${SUNSHINE_SOURCE_ASSETS_DIR}/macos/Lumax.provisionprofile\")
          endif()
          set(_hid_entitlements \"${SUNSHINE_SOURCE_ASSETS_DIR}/macos/entitlements.hid.plist\")
          if(EXISTS \"\${_profile_src}\" AND EXISTS \"\${_hid_entitlements}\")
              file(READ \"\${_profile_src}\" _profile_bytes HEX)
              # 50726f766973696f6e656444657669636573 == ProvisionedDevices (present in Development profiles, absent in Developer ID)
              string(FIND \"\${_profile_bytes}\" \"50726f766973696f6e656444657669636573\" _is_dev_profile)
              set(_id_str \"${APPLE_CODESIGN_IDENTITY}\")
              if((NOT _is_dev_profile EQUAL -1 AND _id_str MATCHES \"Apple Development\") OR
                 (_is_dev_profile EQUAL -1 AND _id_str MATCHES \"Developer ID\"))
                  file(COPY_FILE \"\${_profile_src}\" \"\${_app}/Contents/embedded.provisionprofile\")
                  set(_selected_entitlements \"\${_hid_entitlements}\")
                  message(STATUS \"Embedded provisioning profile and virtual HID entitlements into \${_app}\")
              endif()
          endif()

          # Sign the app last
          execute_process(COMMAND /usr/bin/codesign --verbose=2
              --sign \"${APPLE_CODESIGN_IDENTITY}\" \"\${_app}\"
              --entitlements \"\${_selected_entitlements}\"
              --force --timestamp --options=runtime
              RESULT_VARIABLE rc3
          )
          if(NOT rc3 EQUAL 0)
              message(FATAL_ERROR \"codesign failed while signing .app\")
          endif()

          # Sign the installer app
          execute_process(COMMAND /usr/bin/codesign --verbose=2
              --sign \"${APPLE_CODESIGN_IDENTITY}\" \"\${_installer}\"
              --force --timestamp --options=runtime
              RESULT_VARIABLE installer_sign_rc
          )
          if(NOT installer_sign_rc EQUAL 0)
              message(FATAL_ERROR \"codesign failed while signing installer .app\")
          endif()

          # Verify
          execute_process(COMMAND /usr/bin/codesign --verify --deep --strict --verbose=2 \"\${_app}\"
              RESULT_VARIABLE rc4
          )
          if(NOT rc4 EQUAL 0)
              message(FATAL_ERROR \"codesign --verify failed\")
          endif()
          execute_process(COMMAND /usr/bin/codesign --verify --deep --strict --verbose=2 \"\${_installer}\"
              RESULT_VARIABLE installer_verify_rc
          )
          if(NOT installer_verify_rc EQUAL 0)
              message(FATAL_ERROR \"codesign --verify failed for installer .app\")
          endif()
        endif()
    " COMPONENT Runtime)

    # DragNDrop
    set(CPACK_PACKAGE_NAME "Lumax")
    set(CPACK_PACKAGE_FILE_NAME "Lumax")
    set(CPACK_BUNDLE_NAME "Lumax")
    set(CPACK_BUNDLE_PLIST "${APPLE_PLIST_FILE}")
    set(CPACK_BUNDLE_ICON "${PROJECT_SOURCE_DIR}/src_assets/macos/build/sunshine.icns")
    set(CPACK_PACKAGING_INSTALL_PREFIX "/")
    set(CPACK_DMG_DS_STORE_SETUP_SCRIPT "${PROJECT_SOURCE_DIR}/src_assets/macos/build/dmg-finder-layout.applescript")
endif()
