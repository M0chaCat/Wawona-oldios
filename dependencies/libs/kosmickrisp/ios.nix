{
  lib,
  pkgs,
  buildPackages,
  common,
  buildModule,
  simulator ? false,
}:

let
  fetchSource = common.fetchSource;
  xcodeUtils = import ../../../utils/xcode-wrapper.nix { inherit lib pkgs; };
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
  # For iOS, we need cross-compiled dependencies, not macOS versions
  # Build dependencies (meson, ninja, python) stay macOS-only (nativeBuildInputs) ✅
  # Runtime dependencies must be cross-compiled for iOS
  # Note: Some dependencies (like spirv-headers) are headers-only and can use macOS version
  # Others need iOS cross-compilation. For now, we'll use macOS versions where possible
  # and cross-compile when needed. LLVM/Clang can use macOS versions for cross-compilation.
  # Build iOS dependencies first so we can reference their paths
  zlibIOS = buildModule.buildForIOS "zlib" { inherit simulator; };
  zstdIOS = buildModule.buildForIOS "zstd" { inherit simulator; };
  expatIOS = buildModule.buildForIOS "expat" { inherit simulator; };
  spirvToolsIOS = buildModule.buildForIOS "spirv-tools" { inherit simulator; };

  getDeps =
    depNames:
    map (
      depName:
      if depName == "zlib" then
        zlibIOS
      else if depName == "zstd" then
        zstdIOS
      else if depName == "expat" then
        expatIOS
      else if depName == "spirv-tools" then
        spirvToolsIOS
      else if depName == "spirv-headers" then
        pkgs.spirv-headers # Headers-only, macOS OK
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
  name = "kosmickrisp-ios";
  inherit src patches;
  nativeBuildInputs = with buildPackages; [
    meson
    ninja
    pkg-config
    clang
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
  ];
  # Metal frameworks are linked via -framework flags, not as buildInputs
  # Mesa's meson.build will find them via pkg-config or direct linking
  buildInputs = depInputs;

  postPatch = ''
        echo "DEBUG: Starting postPatch"
        set -x

        # Patch MTLCopyAllDevices (iOS 18.0+) for older iOS versions
        # We inject a compatibility shim at the top of mtl_device.m
        # This replaces MTLCopyAllDevices() with a fallback using MTLCreateSystemDefaultDevice()
        # which is appropriate for iOS (usually single GPU)
        echo "Patching MTLCopyAllDevices usage in src/kosmickrisp/bridge/mtl_device.m"
        sed -i '1i\
    #import <Metal/Metal.h>\
    #include <Availability.h>\
    // Compatibility shim for MTLCopyAllDevices (iOS 18.0+)\
    // If we are targeting older iOS, or if the symbol is weak-linked but we want to be safe\
    static inline NSArray<id<MTLDevice>> * Compat_MTLCopyAllDevices() {\
        if (@available(iOS 18.0, *)) {\
            return MTLCopyAllDevices();\
        } else {\
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();\
            return device ? @[device] : @[];\
        }\
    }\
    #define MTLCopyAllDevices Compat_MTLCopyAllDevices' src/kosmickrisp/bridge/mtl_device.m

        # Patch peerGroupID and peerIndex (missing on iOS < 18.0 or Mac-only)
        echo "Patching peerGroupID/peerIndex in src/kosmickrisp/bridge/mtl_device.m"
        # Replace property access with 0
        sed -i 's/device\.peerGroupID/0/g' src/kosmickrisp/bridge/mtl_device.m
        sed -i 's/\[device peerGroupID\]/0/g' src/kosmickrisp/bridge/mtl_device.m
        sed -i 's/device\.peerIndex/0/g' src/kosmickrisp/bridge/mtl_device.m
        sed -i 's/\[device peerIndex\]/0/g' src/kosmickrisp/bridge/mtl_device.m

        # Patch MTLResidencySet usage in mtl_residency_set.m
        echo "Patching MTLResidencySet in src/kosmickrisp/bridge/mtl_residency_set.m"
        # Initialize error to avoid uninitialized usage warning
        sed -i 's/NSError \*error;/NSError *error = nil;/g' src/kosmickrisp/bridge/mtl_residency_set.m
        # Wrap newResidencySetWithDescriptor:error: in @available
        sed -i '/id<MTLResidencySet> set = \[dev newResidencySetWithDescriptor:setDescriptor/,/error:&error\];/c\
          id<MTLResidencySet> set = nil;\
          if (@available(iOS 18.0, *)) {\
              set = [dev newResidencySetWithDescriptor:setDescriptor error:&error];\
          }' src/kosmickrisp/bridge/mtl_residency_set.m


        # Patch meson.build to skip atomic library check for iOS (atomic ops are built-in)
        echo "Patching meson.build to skip atomic library check for iOS..."
        # The meson.build checks if atomic operations need libatomic
        # On iOS, atomic operations are built into the compiler, so we skip this check
        # Find the line: dep_atomic = cc.find_library('atomic') and replace it
        sed -i "s|dep_atomic = cc.find_library('atomic')|dep_atomic = null_dep  # Patched: atomic ops built-in on iOS|" meson.build || true
        
        # Patch iOS-incompatible library checks
        echo "Patching meson.build for iOS compatibility..."
        # iOS doesn't have separate libdl, librt - these functions are in system libs
        # Make these dependencies optional/null - handle the exact format from meson.build
        sed -i "s|dep_dl = cc.find_library('dl', required : true)|dep_dl = null_dep  # Patched: dl functions in system libs on iOS|g" meson.build || true
        sed -i "s|dep_clock = cc.find_library('rt')|dep_clock = null_dep  # Patched: rt functions in system libs on iOS|g" meson.build || true
        # Also handle without required parameter
        sed -i "s|dep_dl = cc.find_library('dl')|dep_dl = null_dep  # Patched: dl functions in system libs on iOS|g" meson.build || true
        
        echo "Patched atomic and dl library checks"
        
        set +x
  '';
  preConfigure = ''
        if [ -z "''${XCODE_APP:-}" ]; then
          XCODE_APP=$(${xcodeUtils.findXcodeScript}/bin/find-xcode || true)
          if [ -n "$XCODE_APP" ]; then
            export XCODE_APP
            export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
            # Put Xcode tools after Nix tools so we pick up Nix python, etc.
            export PATH="$PATH:$DEVELOPER_DIR/usr/bin"
            export SDKROOT="$DEVELOPER_DIR/Platforms/${if simulator then "iPhoneSimulator" else "iPhoneOS"}.platform/Developer/SDKs/${if simulator then "iPhoneSimulator" else "iPhoneOS"}.sdk"
          fi
        fi
        export NIX_CFLAGS_COMPILE=""
        export NIX_CXXFLAGS_COMPILE=""
        if [ -n "''${SDKROOT:-}" ] && [ -d "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin" ]; then
          IOS_CC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
          IOS_CXX="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++"
        else
          IOS_CC="${buildPackages.clang}/bin/clang"
          IOS_CXX="${buildPackages.clang}/bin/clang++"
        fi

        # Common flags for all languages
        # Use -target for proper cross-compilation behavior
        # Include paths for dependencies
        IOS_ARCH="arm64"
        
        COMMON_ARGS="['-target', '$IOS_ARCH-apple-ios26.0${if simulator then "-simulator" else ""}', '-isysroot', '$SDKROOT', '-m${if simulator then "ios-simulator" else "iphoneos"}-version-min=26.0', '-fPIC', '-I${zlibIOS}/include', '-I${zstdIOS}/include', '-I${expatIOS}/include', '-I${spirvToolsIOS}/include']"
        
        # Common link args
        COMMON_LINK_ARGS="['-target', '$IOS_ARCH-apple-ios26.0${if simulator then "-simulator" else ""}', '-isysroot', '$SDKROOT', '-m${if simulator then "ios-simulator" else "iphoneos"}-version-min=26.0', '-L${zlibIOS}/lib', '-L${zstdIOS}/lib', '-L${expatIOS}/lib', '-L${spirvToolsIOS}/lib', '-lz', '-lzstd', '-lexpat', '-framework', 'Metal', '-framework', 'MetalKit', '-framework', 'Foundation', '-framework', 'IOKit']"

        cat > ios-cross-file.txt <<EOF
    [binaries]
    c = '$IOS_CC'
    cpp = '$IOS_CXX'
    objc = '$IOS_CC'
    objcpp = '$IOS_CXX'
    ar = 'ar'
    strip = 'strip'
    pkgconfig = '${buildPackages.pkg-config}/bin/pkg-config'

    [host_machine]
    system = 'darwin'
    cpu_family = 'aarch64'
    cpu = 'aarch64'
    endian = 'little'

    [built-in options]
    c_args = $COMMON_ARGS
    cpp_args = $COMMON_ARGS
    objc_args = $COMMON_ARGS
    objcpp_args = $COMMON_ARGS
    c_link_args = $COMMON_LINK_ARGS
    cpp_link_args = $COMMON_LINK_ARGS
    objc_link_args = $COMMON_LINK_ARGS
    objcpp_link_args = $COMMON_LINK_ARGS
    EOF
  '';
  configurePhase = ''
    runHook preConfigure
    # App Store static-only policy: build static outputs only.
    # Set PKG_CONFIG_PATH for iOS dependencies and SPIRV/LLVM dependencies
    # Note: iOS dependencies may not have pkg-config files, but we include paths anyway
    export PKG_CONFIG_PATH="${zlibIOS}/lib/pkgconfig:${zstdIOS}/lib/pkgconfig:${expatIOS}/lib/pkgconfig:${spirvToolsIOS}/lib/pkgconfig:${pkgs.spirv-headers}/share/pkgconfig:${pkgs.spirv-headers}/lib/pkgconfig:''${PKG_CONFIG_PATH:-}"
    meson setup build \
      --prefix=$out \
      --libdir=$out/lib \
      --default-library=static \
      --cross-file=ios-cross-file.txt \
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
    runHook postInstall
  '';
}
