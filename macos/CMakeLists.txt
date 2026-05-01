cmake_minimum_required(VERSION 3.20)

if(NOT DEFINED CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "macOS architectures" FORCE)
endif()

project(HexEditorMac LANGUAGES CXX OBJCXX)

include(CTest)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OBJCXX_VISIBILITY_PRESET hidden)

# Emit compile_commands.json so clangd (the language server VS Code uses) knows our
# include paths, C++17 standard, and per-target flags. Without this, clangd's in-IDE
# diagnostics flood with fake "HexCore.h not found" / "no member named 'clamp'" errors.
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(NPP_MACOS_DIR "${CMAKE_CURRENT_LIST_DIR}/../../notepad-plus-plus-macos" CACHE PATH "Path to notepad-plus-plus-macos checkout")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")
set(SCINTILLA_INCLUDE "${NPP_MACOS_DIR}/scintilla/include")

if(NOT EXISTS "${NPP_PLUGIN_INCLUDE}/NppPluginInterfaceMac.h")
    message(FATAL_ERROR "NppPluginInterfaceMac.h was not found. Set -DNPP_MACOS_DIR=/path/to/notepad-plus-plus-macos")
endif()

if(NOT EXISTS "${SCINTILLA_INCLUDE}/Scintilla.h")
    message(FATAL_ERROR "Scintilla.h was not found. Set -DNPP_MACOS_DIR=/path/to/notepad-plus-plus-macos")
endif()

add_library(HexEditor SHARED
    src/HexEditor.mm
    src/core/HexCore.cpp
)

target_include_directories(HexEditor PRIVATE
    "${NPP_PLUGIN_INCLUDE}"
    "${SCINTILLA_INCLUDE}"
    "${CMAKE_CURRENT_LIST_DIR}/src/core"
)

target_link_libraries(HexEditor PRIVATE
    "-framework Cocoa"
)

set_target_properties(HexEditor PROPERTIES
    PREFIX ""
    SUFFIX ".dylib"
    OUTPUT_NAME "HexEditor"
)

set(PLUGIN_INSTALL_DIR "$ENV{HOME}/.notepad++/plugins/HexEditor")
install(TARGETS HexEditor DESTINATION "${PLUGIN_INSTALL_DIR}")

# Localizable.<lang>.strings — the plugin reads these at runtime from the install
# directory next to HexEditor.dylib. Embedded English defaults in HexEditor.mm
# carry the UI when these files are missing, but shipping them is required for
# any non-English language to render.
set(HEX_LOCALIZATION_FILES
    "${CMAKE_CURRENT_LIST_DIR}/resources/Localizable.en.strings"
    "${CMAKE_CURRENT_LIST_DIR}/resources/Localizable.en-GB.strings"
    "${CMAKE_CURRENT_LIST_DIR}/resources/Localizable.en-US.strings"
    "${CMAKE_CURRENT_LIST_DIR}/resources/Localizable.de.strings"
)
install(FILES ${HEX_LOCALIZATION_FILES} DESTINATION "${PLUGIN_INSTALL_DIR}")

# Also copy the .strings into the build directory next to the dylib so the test
# harness (which dlopens the build-tree dylib) finds them via dladdr at runtime.
add_custom_command(TARGET HexEditor POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${HEX_LOCALIZATION_FILES}
        "$<TARGET_FILE_DIR:HexEditor>"
    COMMENT "Copying Localizable.*.strings next to HexEditor.dylib"
    VERBATIM
)

if(BUILD_TESTING)
    add_executable(HexEditorCoreTests
        tests/HexCoreTests.cpp
        src/core/HexCore.cpp
    )
    target_include_directories(HexEditorCoreTests PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/src/core"
    )
    add_test(NAME HexEditorCoreTests COMMAND HexEditorCoreTests)
    set_tests_properties(HexEditorCoreTests PROPERTIES LABELS "unit;core")

    add_executable(HexEditorPluginSmokeTests
        tests/HexPluginSmokeTests.mm
    )
    target_include_directories(HexEditorPluginSmokeTests PRIVATE
        "${NPP_PLUGIN_INCLUDE}"
    )
    # Foundation gives us NSUserDefaults to force AppleLanguages = en before dlopen,
    # so the smoke test's English string assertions don't depend on the dev locale.
    target_link_libraries(HexEditorPluginSmokeTests PRIVATE
        "-framework Foundation"
    )
    add_dependencies(HexEditorPluginSmokeTests HexEditor)
    add_test(NAME HexEditorPluginSmokeTests
        COMMAND HexEditorPluginSmokeTests "$<TARGET_FILE:HexEditor>"
    )
    set_tests_properties(HexEditorPluginSmokeTests PROPERTIES LABELS "smoke;plugin")
endif()

find_program(XCODEGEN_EXECUTABLE xcodegen)
find_program(XCODEBUILD_EXECUTABLE xcodebuild)
if(BUILD_TESTING AND XCODEGEN_EXECUTABLE AND XCODEBUILD_EXECUTABLE)
    add_test(
        NAME HexEditorXCTestUI
        COMMAND "${CMAKE_CURRENT_LIST_DIR}/ui-tests-xcode/run-tests.sh"
    )
    set_tests_properties(HexEditorXCTestUI PROPERTIES
        LABELS "ui;xctest"
        ENVIRONMENT "NPP_MACOS_APP=${NPP_MACOS_DIR}/build/Notepad++.app"
    )
endif()
