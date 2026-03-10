# Vulkan CTS for macOS (uses KosmicKrisp when provided)
{
  lib,
  pkgs,
  buildTargets ? "deqp-vk",
}:

let
  common = import ./common.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = "vulkan-cts-macos";
  version = common.version;

  src = common.src;

  prePatch = common.prePatch;

  nativeBuildInputs = with pkgs; [
    cmake
    ninja
    pkg-config
    python3
    makeWrapper
  ];

  buildInputs = with pkgs; [
    ffmpeg
    libffi
    libpng
    vulkan-headers
    vulkan-loader
    vulkan-utility-libraries
    zlib
    apple-sdk_26
  ];

  depsBuildBuild = with pkgs; [
    pkg-config
  ];

  cmakeFlags = [
    "-DCMAKE_INSTALL_BINDIR=bin"
    "-DCMAKE_INSTALL_LIBDIR=lib"
    "-DCMAKE_INSTALL_INCLUDEDIR=include"
    "-DDEQP_TARGET=osx"
    "-DSELECTED_BUILD_TARGETS=${buildTargets}"
    (lib.cmakeFeature "DGLSLANG_INSTALL_DIR" "${pkgs.glslang}")
    (lib.cmakeFeature "DSPIRV_HEADERS_INSTALL_DIR" "${pkgs.spirv-headers}")
    (lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_SHADERC" "${common.sources.shaderc-src}")
  ];

  postInstall = ''
    mkdir -p $out/bin $out/archive-dir
    [ -f external/vulkancts/modules/vulkan/deqp-vk ] && cp -a external/vulkancts/modules/vulkan/deqp-vk $out/bin/ || true
    [ -d external/vulkancts/modules/vulkan/vulkan ] && cp -a external/vulkancts/modules/vulkan/vulkan $out/archive-dir/ || true
    [ -d external/vulkancts/modules/vulkan/vk-default ] && cp -a external/vulkancts/modules/vulkan/vk-default $out/ || true
    [ -f external/openglcts/modules/glcts ] && cp -a external/openglcts/modules/glcts $out/bin/ || true
    [ -f external/openglcts/modules/cts-runner ] && cp -a external/openglcts/modules/cts-runner $out/bin/ || true
  '';

  postFixup = ''
    if [ -f $out/bin/deqp-vk ]; then
      install_name_tool -add_rpath "${pkgs.vulkan-loader}/lib" $out/bin/deqp-vk || true
      wrapProgram $out/bin/deqp-vk \
        --add-flags "--deqp-archive-dir=$out/archive-dir"
    fi
  '';

  meta = {
    description = "Khronos Vulkan Conformance Tests (macOS)";
    homepage = "https://github.com/KhronosGroup/VK-GL-CTS";
    license = lib.licenses.asl20;
    platforms = lib.platforms.darwin;
  };
})
