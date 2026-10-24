cmake_minimum_required(VERSION 3.20)

# ============================================================================
# BLiNX: The Time Sweeper (Xbox, 2002, PAL) - Static Recompilation
#
# Built on the xboxrecomp toolkit (../xboxrecomp, takedawn branch), the same
# way Fable and Takedawn are built. regen.sh writes the lifted C to
# src/recomp/gen/ from the user's own default.xbe.
# ============================================================================

project(blinx_recomp C)

# Windows host. The toolkit's SDL2 + Vulkan host needs llvm-mingw, SDL2,
# Vulkan headers and glslang (MSVC cannot build it); the MSVC path is GDI +
# Direct3D 11. Bring-up starts on MSVC, where the CPU and kernel side gets
# debugged; the Vulkan host comes after the title boots.
option(BLINX_WIN_VULKAN "Windows: build the SDL2 + Vulkan host" OFF)
if(WIN32)
    set(XBOXRECOMP_WIN_VULKAN ${BLINX_WIN_VULKAN} CACHE BOOL
        "Windows: SDL2 window/audio/pad and the Vulkan backend" FORCE)
endif()

# The unpacked disc (tools.xiso unpack). main.c reads default.xbe there and
# maps D:\ to it.
set(BLINX_GAME_DIR "${CMAKE_CURRENT_SOURCE_DIR}/game_files" CACHE PATH
    "Unpacked Blinx disc (default.xbe, media)")
file(TO_NATIVE_PATH "${BLINX_GAME_DIR}" _blinx_game_dir_native)
string(REPLACE "\\" "\\\\" _blinx_game_dir_native "${_blinx_game_dir_native}")

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Common definitions
add_compile_definitions(
    WIN32_LEAN_AND_MEAN
    NOMINMAX
)

# ── xboxrecomp toolkit ──────────────────────────────────────────
#
# Option A: xboxrecomp as a subdirectory (simplest)
#   Place xboxrecomp/ next to your game project and use a relative path.
#
# Option B: find_package (if you install xboxrecomp system-wide)
#   find_package(xboxrecomp REQUIRED)
#
# Adjust this path to point to your xboxrecomp clone:
set(XBOXRECOMP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../xboxrecomp" CACHE PATH
    "Path to the xboxrecomp toolkit root directory")

# Add xboxrecomp as a subdirectory -- this builds all 6 runtime libraries
# and provides the 'xboxrecomp' umbrella target to link against.
# The toolkit's enhancements layer: render.scale (internal resolution) and the
# present options, from enhance.toml beside the executable and RECOMP_* over
# it. src/main.c sets the defaults.
set(XBOXRECOMP_ENHANCE ON CACHE BOOL
    "Build the enhancements layer (enhance.toml, RECOMP_RENDER_SCALE, ...)" FORCE)
# The settings overlay (Back+Start or F1: render scale, anti-aliasing,
# anisotropic filtering, ...), as in Takedawn. Dear ImGui over the SDL2 +
# Vulkan host's present; the GDI + D3D11 host has none.
if(BLINX_WIN_VULKAN)
    set(XBOXRECOMP_OVERLAY ON CACHE BOOL "Build the in-game settings overlay" FORCE)
endif()

add_subdirectory(${XBOXRECOMP_DIR} ${CMAKE_BINARY_DIR}/xboxrecomp)

# ── Recompiled game executable ──────────────────────────────────

# Collect generated recompiled code.
# The recomp pipeline outputs files into src/recomp/gen/.
# With --split 1000, you get gen_0000.c, gen_0001.c, etc.
# CONFIGURE_DEPENDS so re-running the recompiler picks up added/removed files
# without a manual re-configure. A plain GLOB is evaluated once at configure
# time, so a newly generated file (an extra chunk, recomp_stubs_unresolved.c)
# is silently left out of the build and shows up as unresolved externals.
file(GLOB RECOMP_GEN_SOURCES CONFIGURE_DEPENDS "src/recomp/gen/*.c")

# Core game sources
set(GAME_SOURCES
    src/main.c
    src/recomp_manual.c
    src/movie_player.c   # the SFD movies, decoded by ffmpeg on the host
    # Add game-specific sources here, e.g.:
    # src/asset_loader.c
    # src/custom_renderer.c
)

# The recomp pipeline also generates a dispatch header and function declarations.
# These are included by the generated .c files:
#   src/recomp/gen/recomp_funcs.h    - extern declarations for all recompiled functions
#   src/recomp/recomp_dispatch.h     - binary search dispatch table
#   src/recomp/recomp_types.h        - register model, ICALL macros, MEM helpers

add_executable(${PROJECT_NAME}
    ${GAME_SOURCES}
    ${RECOMP_GEN_SOURCES}
)

# Link against the xboxrecomp umbrella target (all 6 runtime libraries)
target_link_libraries(${PROJECT_NAME} PRIVATE xboxrecomp)

# Include paths for generated recomp headers
target_compile_definitions(${PROJECT_NAME} PRIVATE
    BLINX_GAME_DIR="${_blinx_game_dir_native}"
)

target_include_directories(${PROJECT_NAME} PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/recomp
    ${XBOXRECOMP_DIR}/include
    # recomp_manual.c and main.c: xbox_memory_layout.h (RECOMP_TLS) and the
    # kernel's own headers.
    ${XBOXRECOMP_DIR}/src/kernel
)

if(XBOXRECOMP_WIN_VULKAN)
    # SDL2 (window, audio, pad) for the Vulkan host.
    find_package(SDL2 REQUIRED)
    target_link_libraries(${PROJECT_NAME} PRIVATE SDL2::SDL2)
endif()

# Windows SDK libraries needed at link time
target_link_libraries(${PROJECT_NAME} PRIVATE
    d3d11
    dxgi
    dxguid
    xinput
    winmm
    # Lets the fault handler resolve the host RIP back to the generated
    # function's symbol, i.e. to the guest function that faulted.
    dbghelp
)

# MSVC-specific: large address aware, increase section limit for big generated files
if(MSVC)
    target_link_options(${PROJECT_NAME} PRIVATE
        /LARGEADDRESSAWARE
    )
    # The generated code files can be very large. Increase object file section limit.
    target_compile_options(${PROJECT_NAME} PRIVATE /bigobj)
    # Half the cores for /MP, as Takedawn does: each cl.exe holds a whole
    # generated chunk at /O2, and saturating cores and RAM stalls the desktop.
    cmake_host_system_information(RESULT _blinx_cores QUERY NUMBER_OF_LOGICAL_CORES)
    math(EXPR _blinx_jobs "${_blinx_cores} / 2")
    if(_blinx_jobs LESS 1)
        set(_blinx_jobs 1)
    endif()
    set(BLINX_COMPILE_JOBS "${_blinx_jobs}" CACHE STRING
        "Parallel cl.exe processes for the recompiled sources (/MP<n>)")
    target_compile_options(${PROJECT_NAME} PRIVATE /MP${BLINX_COMPILE_JOBS})
    set_source_files_properties(${RECOMP_GEN_SOURCES} PROPERTIES COMPILE_FLAGS "/w")
else()
    # llvm-mingw, as in Takedawn: the 16 MiB main-thread stack the guest runs
    # deep on, a fixed image, and the console subsystem (SDL2's mingw config
    # asks for -mwindows) so the log goes to the terminal that started it.
    target_link_options(${PROJECT_NAME} PRIVATE
        -Wl,--stack,16777216 -Wl,--disable-dynamicbase -Wl,--disable-high-entropy-va
        -Wl,--subsystem,console)
    target_compile_definitions(${PROJECT_NAME} PRIVATE _CRT_SECURE_NO_WARNINGS)
    # The generated chunks warn by the thousand. The executable stays
    # unstripped so the fault handler names sub_XXXXXXXX.
    set_source_files_properties(${RECOMP_GEN_SOURCES} PROPERTIES COMPILE_OPTIONS "-w;-gline-tables-only")
endif()

# ── Game-specific additions ─────────────────────────────────────
#
# Add any game-specific libraries, loaders, or custom renderers below.
# Examples:
#
# # Custom texture loader for your game's format
# target_sources(${PROJECT_NAME} PRIVATE src/texture_loader.c)
#
# # If your game uses RenderWare, you may need a RW bridge layer
# target_sources(${PROJECT_NAME} PRIVATE src/rw_bridge.c)
#
# # Additional compile definitions for debugging
# target_compile_definitions(${PROJECT_NAME} PRIVATE
#     ENABLE_ICALL_TRACE=1
#     VERBOSE_KERNEL_LOG=1
# )
