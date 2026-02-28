{
  lib,
  pkgs,
  common,
  buildModule,
}:

let
  fetchSource = common.fetchSource;
  # Pin to a specific commit for reproducible builds
  # Using branch = "main" is not reproducible as it changes over time
  mesaSource = {
    source = "gitlab";
    owner = "mesa";
    repo = "mesa";
    rev = "9994db58b3afe385724cfb3562b9fc0a7fb82723";
    sha256 = "sha256-lgsYsJNepGTEWDPmD7H6teijULlxyPl9akcDXvSAU60=";
  };
  src = fetchSource mesaSource;
  buildFlags = [
    "-Dvulkan-drivers=kosmickrisp"
    "-Dgallium-drivers="
    "-Dplatforms="
    "-Dglx=disabled"
    "-Degl=disabled"
    "-Dgbm=disabled"
    "-Dtools="
    "-Dvulkan-beta=true"
    "-Dbuildtype=release"
    "-Dglvnd=disabled"
    "-Dgallium-va=disabled"
    "-Dllvm=disabled"
  ];
  patches = [ ];
  getDeps =
    depNames:
    map (
      depName:
      if depName == "zlib" then
        pkgs.zlib
      else if depName == "zstd" then
        pkgs.zstd
      else if depName == "expat" then
        pkgs.expat
      else if depName == "spirv-tools" then
        pkgs.spirv-tools
      else if depName == "spirv-headers" then
        pkgs.spirv-headers
      # Lua is optional - only needed for Freedreno tools, not kosmickrisp
      # else if depName == "lua" then pkgs.lua5_4
      else
        throw "Unknown dependency: ${depName}"
    ) depNames;
  depInputs = getDeps [
    "zlib"
    "zstd"
    "expat"
    "spirv-tools"
    "spirv-headers"
  ];
in
pkgs.stdenv.mkDerivation {
  name = "kosmickrisp-macos";
  inherit src patches;
  nativeBuildInputs = with pkgs; [
    meson
    ninja
    pkg-config
    (python3.withPackages (
      ps: with ps; [
        setuptools
        pip
        packaging
        mako
        pyyaml
      ]
    ))
    bison
    flex
    pkgs.apple-sdk_26 # macOS SDK 26+
  ];
  # Metal frameworks are linked via -framework flags, not as buildInputs
  # Mesa's meson.build will find them via pkg-config or direct linking
  buildInputs = depInputs;
  postPatch = ''
    echo "Skipping Clang patch since LLVM is disabled."
  '';
  configurePhase = ''
    runHook preConfigure
    # Ensure we build as .dylib (shared library) for macOS
    # Use latest macOS SDK (26+)
    MACOS_SDK="${pkgs.apple-sdk_26}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    MACOS_VERSION_MIN="26.0"

    # Link Metal frameworks
    export LDFLAGS="-isysroot $MACOS_SDK -mmacosx-version-min=$MACOS_VERSION_MIN -framework Metal -framework MetalKit -framework Foundation -framework IOKit"
    export CPPFLAGS="-isysroot $MACOS_SDK -mmacosx-version-min=$MACOS_VERSION_MIN"
    export CFLAGS="-isysroot $MACOS_SDK -mmacosx-version-min=$MACOS_VERSION_MIN"
    export CXXFLAGS="-isysroot $MACOS_SDK -mmacosx-version-min=$MACOS_VERSION_MIN"

    export PKG_CONFIG_PATH="${pkgs.spirv-tools}/lib/pkgconfig:${pkgs.spirv-headers}/lib/pkgconfig:''${PKG_CONFIG_PATH:-}"

    # Set SDKROOT for Meson to find Metal frameworks
    export SDKROOT="$MACOS_SDK"

    # Our patch allows specifying clang-libdir via meson option if needed
    # For now, let Mesa search in LLVM libdir (our patch makes it more flexible)
    meson setup build \
      --prefix=$out \
      --libdir=$out/lib \
      --default-library=shared \
      ${lib.concatMapStringsSep " \\\n  " (flag: flag) buildFlags}
    runHook postConfigure
  '';
  buildPhase = ''
    runHook preBuild
    meson compile -C build
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    meson install -C build

    # Ensure ICD JSON manifest exists for the Vulkan loader
    mkdir -p $out/share/vulkan/icd.d
    if [ ! -f $out/share/vulkan/icd.d/kosmickrisp_icd.json ] && \
       [ ! -f $out/share/vulkan/icd.d/kosmickrisp_icd.*.json ]; then
      # Mesa did not generate a manifest — create one manually
      # Find the actual .dylib name (may be libvulkan_kosmickrisp.dylib or similar)
      VK_LIB=$(find $out/lib -name "libvulkan_kosmickrisp*.dylib" -o -name "libVkICD_kosmickrisp*.dylib" | head -1)
      if [ -z "$VK_LIB" ]; then
        VK_LIB=$(find $out/lib -name "*.dylib" | head -1)
      fi
      if [ -n "$VK_LIB" ]; then
        cat > $out/share/vulkan/icd.d/kosmickrisp_icd.json <<ICDJSON
    {
        "file_format_version": "1.0.1",
        "ICD": {
            "library_path": "$VK_LIB",
            "api_version": "1.3.0",
            "is_portability_driver": true
        }
    }
    ICDJSON
        echo "Generated ICD manifest pointing to $VK_LIB"
      else
        echo "WARNING: No kosmickrisp .dylib found in $out/lib — ICD manifest not created"
      fi
    else
      echo "Mesa-generated ICD manifest found"
      # Patch library_path to use absolute nix store path
      for f in $out/share/vulkan/icd.d/*.json; do
        sed -i "s|\"library_path\": \"\.\./\.\./|\"library_path\": \"$out/|g" "$f"
        sed -i "s|\"library_path\": \"lib/|\"library_path\": \"$out/lib/|g" "$f"
      done
    fi

    runHook postInstall
  '';
}
