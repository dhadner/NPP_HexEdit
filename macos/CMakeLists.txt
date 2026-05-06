cmake_minimum_required(VERSION 3.20)

if(NOT DEFINED CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "macOS architectures" FORCE)
endif()

project(HexEditorMac VERSION 1.1.0 LANGUAGES CXX OBJCXX)

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

# Opt-in sanitizer + fuzz infrastructure. Both are off by default so the regular
# Release build (used for the shipped HexEditor.dylib) stays unaffected.
#
# ENABLE_SANITIZERS=ON adds -fsanitize=address,undefined to every target. Apple
# Clang ships the runtime libraries for both, so no extra install is required —
# but the resulting build is ~2× slower and grows the binary, so it's a separate
# build directory rather than the universal one used for releases.
#
# ENABLE_FUZZ_TESTS=ON additionally builds the libFuzzer harnesses under fuzz/.
# That requires Homebrew LLVM (`brew install llvm`) since Apple Clang carries
# the -fsanitize=fuzzer flag but NOT the libFuzzer runtime archive — link will
# fail with "library 'libclang_rt.fuzzer_osx.a' not found" on the system clang.
# When ENABLE_FUZZ_TESTS is set, this script switches CMAKE_CXX_COMPILER to the
# Homebrew clang++ and errors out clearly if it isn't installed.
option(ENABLE_SANITIZERS "Build with -fsanitize=address,undefined" OFF)
option(ENABLE_FUZZ_TESTS "Build the libFuzzer harnesses under fuzz/ (requires brew install llvm)" OFF)

if(ENABLE_FUZZ_TESTS)
    if(NOT ENABLE_SANITIZERS)
        message(STATUS "ENABLE_FUZZ_TESTS implies ENABLE_SANITIZERS; turning the latter on.")
        set(ENABLE_SANITIZERS ON)
    endif()
    # Force a single architecture — libFuzzer can't run a universal binary.
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Single-arch build for libFuzzer" FORCE)
    if(NOT EXISTS "/opt/homebrew/opt/llvm/bin/clang++")
        message(FATAL_ERROR
            "ENABLE_FUZZ_TESTS=ON requires Homebrew LLVM. Install with: brew install llvm\n"
            "Apple Clang ships the -fsanitize=fuzzer flag but not libFuzzer's runtime archive.")
    endif()
    # Reconfigure to the Homebrew toolchain BEFORE project() consumed the system
    # compiler. Since project() ran above, the only safe move is to fail loudly
    # if ENABLE_FUZZ_TESTS was set on a build dir that was first configured with
    # the system clang. Force a clean reconfigure.
    if(NOT CMAKE_CXX_COMPILER STREQUAL "/opt/homebrew/opt/llvm/bin/clang++")
        message(FATAL_ERROR
            "ENABLE_FUZZ_TESTS=ON needs the Homebrew clang++ but the cached compiler is\n"
            "  ${CMAKE_CXX_COMPILER}\n"
            "Use a fresh build directory:\n"
            "  cmake -S macos -B macos/build-fuzz -DENABLE_FUZZ_TESTS=ON \\\n"
            "    -DCMAKE_CXX_COMPILER=/opt/homebrew/opt/llvm/bin/clang++ \\\n"
            "    -DCMAKE_C_COMPILER=/opt/homebrew/opt/llvm/bin/clang")
    endif()
endif()

if(ENABLE_SANITIZERS)
    # ASan + UBSan + frame-pointer for readable stack traces. -O1 keeps inlining
    # under control while still being faster than -O0; the sanitizer slowdown
    # dominates either way. clang automatically embeds an LC_RPATH pointing
    # at the toolchain's libclang_rt.asan_osx_dynamic.dylib when
    # -fsanitize=address is on the link line, for both executables and dylibs,
    # so dyld can resolve the runtime when NPP loads our plugin.
    add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer -O1 -g)
    add_link_options(-fsanitize=address,undefined)
    message(STATUS "Sanitizers enabled: ASan + UBSan")
endif()

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

target_compile_definitions(HexEditor PRIVATE
    HEX_PLUGIN_VERSION="${PROJECT_VERSION}"
)

set_target_properties(HexEditor PROPERTIES
    PREFIX ""
    SUFFIX ".dylib"
    # OUTPUT_NAME is the on-disk file name; the CMake target name (HexEditor)
    # stays unchanged to keep cross-references stable. The shipped artifact is
    # HexEditor.dylib because that's the directory + binary name the upstream
    # Notepad++ plugin registry expects (must match the directory name under
    # ~/.notepad++/plugins/, see PLUGIN_INSTALL_DIR below).
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
    "${CMAKE_CURRENT_LIST_DIR}/resources/Localizable.ar.strings"
    "${CMAKE_CURRENT_LIST_DIR}/resources/Localizable.de.strings"
    "${CMAKE_CURRENT_LIST_DIR}/resources/Localizable.es.strings"
    "${CMAKE_CURRENT_LIST_DIR}/resources/Localizable.es-ES.strings"
    "${CMAKE_CURRENT_LIST_DIR}/resources/Localizable.es-MX.strings"
    "${CMAKE_CURRENT_LIST_DIR}/resources/Localizable.fr.strings"
    "${CMAKE_CURRENT_LIST_DIR}/resources/Localizable.he.strings"
    "${CMAKE_CURRENT_LIST_DIR}/resources/Localizable.it.strings"
    "${CMAKE_CURRENT_LIST_DIR}/resources/Localizable.pl.strings"
    "${CMAKE_CURRENT_LIST_DIR}/resources/Localizable.ru.strings"
    "${CMAKE_CURRENT_LIST_DIR}/resources/Localizable.uk.strings"
    "${CMAKE_CURRENT_LIST_DIR}/resources/Localizable.zh-Hans.strings"
)
install(FILES ${HEX_LOCALIZATION_FILES} DESTINATION "${PLUGIN_INSTALL_DIR}")

# Toolbar icons — light + dark variants. Shipped flat in the plugin directory
# (the host picks the appropriate one based on appearance).
set(HEX_ICON_FILES
    "${CMAKE_CURRENT_LIST_DIR}/resources/toolbar.png"
    "${CMAKE_CURRENT_LIST_DIR}/resources/toolbar_dark.png"
)
install(FILES ${HEX_ICON_FILES} DESTINATION "${PLUGIN_INSTALL_DIR}")

# Also copy the .strings + icons into the build directory next to the dylib so the
# test harness (which dlopens the build-tree dylib) finds them via dladdr at runtime.
add_custom_command(TARGET HexEditor POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${HEX_LOCALIZATION_FILES}
        ${HEX_ICON_FILES}
        "$<TARGET_FILE_DIR:HexEditor>"
    COMMENT "Copying Localizable.*.strings + toolbar icons next to HexEditor.dylib"
    VERBATIM
)

# Distribution zip: package the dylib + .strings + icons in a flat layout under a
# top-level "HexEditor/" directory inside the archive, so unzipping into
# ~/.notepad++/plugins/ produces the expected ~/.notepad++/plugins/HexEditor/
# layout. Built as a POST_BUILD step on the dylib target so every build produces
# the artifact ready for upload to a GitHub Release; the .zip itself is gitignored.
# Naming convention: nppHexEditorPlugin-x.y.z.zip per upstream NPP plugin
# distribution conventions.
set(HEX_DIST_STAGING "${CMAKE_BINARY_DIR}/dist-staging/HexEditor")
set(HEX_DIST_ZIP "${CMAKE_BINARY_DIR}/nppHexEditorPlugin-${PROJECT_VERSION}.zip")
add_custom_command(TARGET HexEditor POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${HEX_DIST_STAGING}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${HEX_DIST_STAGING}"
    COMMAND ${CMAKE_COMMAND} -E copy
        "$<TARGET_FILE:HexEditor>"
        ${HEX_LOCALIZATION_FILES}
        ${HEX_ICON_FILES}
        "${HEX_DIST_STAGING}"
    COMMAND ${CMAKE_COMMAND} -E rm -f "${HEX_DIST_ZIP}"
    COMMAND ${CMAKE_COMMAND} -E chdir "${CMAKE_BINARY_DIR}/dist-staging"
        ${CMAKE_COMMAND} -E tar c "${HEX_DIST_ZIP}" --format=zip "HexEditor"
    COMMENT "Packaging nppHexEditorPlugin-${PROJECT_VERSION}.zip"
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

# libFuzzer harnesses. Each harness is a tiny TU that exposes
# LLVMFuzzerTestOneInput against a single HexCore parser, linked with the
# fuzzer + sanitizer runtimes and run via ctest -L fuzz with a short
# time budget. See fuzz/README.md for the full list and how to extend.
if(ENABLE_FUZZ_TESTS)
    set(FUZZ_DURATION_SEC 30 CACHE STRING "Per-harness max_total_time for ctest -L fuzz runs")
    set(HEX_FUZZ_HARNESSES
        fuzz_parseRectClipboardText
        fuzz_decodeRectPayload
        fuzz_extractRectBytes
        fuzz_makeRectSelection
        fuzz_stripHexDumpAddressAndAscii
        fuzz_parseSearchPattern
        fuzz_parseHexClipboardText
        fuzz_resolveGotoOffset
    )
    foreach(harness ${HEX_FUZZ_HARNESSES})
        add_executable(${harness}
            "fuzz/${harness}.cpp"
            src/core/HexCore.cpp
        )
        target_include_directories(${harness} PRIVATE
            "${CMAKE_CURRENT_LIST_DIR}/src/core"
        )
        target_compile_options(${harness} PRIVATE -fsanitize=fuzzer)
        target_link_options(${harness} PRIVATE -fsanitize=fuzzer)
        add_test(NAME ${harness}
            COMMAND ${harness}
                "-max_total_time=${FUZZ_DURATION_SEC}"
                "-print_final_stats=1"
        )
        set_tests_properties(${harness} PROPERTIES LABELS "fuzz")
    endforeach()
    message(STATUS "Fuzz harnesses enabled: ${HEX_FUZZ_HARNESSES} (per-test max_total_time=${FUZZ_DURATION_SEC}s)")
endif()
