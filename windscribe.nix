{ lib
, pkgs
, stdenv
, fetchFromGitHub
, fetchzip
, buildGoModule

, perl
, autoreconfHook
, automake
, cmake

, qt6
, boost
, c-ares
, wireguard-tools
}:

let

  # windscribe app sources
  windscribe_version = "2.9.9";
  windscribe_src = fetchFromGitHub {
    owner = "windscribe";
    repo = "Desktop-App";
    rev = "v${windscribe_version}";
    hash = {
      "2.9.9" = "sha256-E/eiBDaFRsooqtg5bRU9CKoXbbJ7TVLY/yZRiREXIKo=";
      "2.10.10" = "sha256-A1JPEayJt44Jk88dwWrlnNDFTA9C5tWuziVbu7blAPQ=";
    }.${windscribe_version};
  };

  custom_openssl_ech_draft = pkgs.openssl_3_3.overrideAttrs (finalAttrs: previousAttrs: {
    version = "3.3.0+windscribe-${windscribe_version}";
    src = fetchFromGitHub { # https://github.com/Windscribe/Desktop-App/blob/bc84faf99c5f08b4b6b310fadf9a40eaadbdb771/tools/deps/install_openssl_ech_draft.py#L26
      owner = "sftcd";
      repo = "openssl";
      rev = "ff6d726fc05b7cdd6eddc1b92cae507d6ddc7aee";
      hash = "sha256-2+IMvW11IGeR66did0OaxWN2JVXSl///5YTi2q034KE=";
    };
    # (copy these over before the patch phase so nixpkg's patches can be applied too)
    prePatch = ''
      ${previousAttrs.prePatch or ""}
      cp -rf "${windscribe_src}/tools/deps/custom_openssl_ech_draft/." .
    '';
  });

  custom_openvpn = pkgs.openvpn.overrideAttrs (finalAttrs: previousAttrs: {
    pname = "windscribeopenvpn";
    version = "2.6.8";
    # split between sources for windows vs non is following what their build script does, see:
    #  https://github.com/Windscribe/Desktop-App/blob/v2.9.9/tools/deps/install_openvpn.py#L24-L29
    #  https://github.com/Windscribe/Desktop-App/blob/v2.9.9/tools/deps/install_openvpn.py#L103-L108
    src = if stdenv.targetPlatform.isWindows
      then fetchFromGitHub {
        owner = "OpenVPN";
        repo = "openvpn";
        rev = "v${finalAttrs.version}";
        hash = "sha256-uGRQ4fRGm0eEKGpliOBaRD2wH60+TgCIUnWMK7LPfRI=";
      }
      else fetchzip {
        url = "https://swupdate.openvpn.org/community/releases/openvpn-${finalAttrs.version}.tar.gz";
        hash = "sha256-RrOnPD9onNykQnzMZuiSOQ4R08qbNWM6krNuCHZ8CMo=";
      };
    openssl = custom_openssl_ech_draft;
    postPatch = ''
      cp -rf "${windscribe_src}/tools/deps/custom_openvpn/." .
      ${previousAttrs.postPatch or ""}
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/opt/windscribe
      cp src/openvpn/openvpn $out/opt/windscribe/windscribeopenvpn
      runHook postInstall
    '';
    dontFixup = true;
  });

  windscribewstunnel = buildGoModule rec {
    pname = "windscribewstunnel";
    version = "1.0.1";
    src = fetchFromGitHub {
      owner = "Windscribe";
      repo = "wstunnel";
      rev = "${version}";
      hash = "sha256-eGz7nSLDupUhjBlFmVXIedT02VyCzX9vmY4ggUSH7zY=";
    };
    vendorHash = "sha256-i6tP8EweWr1wlBnkfPwXvd4ovRCHAeObs1ZID//3yZU=";
    # (their patch files for this seem to only be relevant to windows stuff so not bothering with that yet)
    # postPatch = ''
    #   cp -rf "${windscribe_src}/tools/deps/custom_wstunnel/" .
    # '';
    buildPhase = ''
      runHook preBuild
      go build -o build/windscribewstunnel -a "-gcflags=all=-l -B" "-ldflags=-w -s"
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/opt/windscribe
      cp build/windscribewstunnel $out/opt/windscribe/windscribewstunnel
      runHook postInstall
    '';
  };

  custom_curl = stdenv.mkDerivation (finalAttrs: {
    pname = "curl";
    version = "8.5.0+windscribe-${windscribe_version}";
    src = fetchFromGitHub {
      owner = "sftcd";
      repo = "curl";
      rev = "ecf5952a8b668d59f7da4d082c91d555f3689aec";
      hash = "sha256-ugObSS2CYcZxagONK5HnUqNAWLfHxYRX7xEjxVTrnTw=";
    };
    nativeBuildInputs = [
      perl
      autoreconfHook
      automake
    ];
    buildInputs = [ custom_openssl_ech_draft ];
    configureFlags = [
      "--with-openssl=${lib.getDev custom_openssl_ech_draft}"
      "--enable-ech" "--enable-httpsrr" "--without-brotli" "--without-zstd"
    ];
    patchPhase = ''
      runHook prePatch
      cp -rfv "${windscribe_src}/tools/deps/custom_curl/." .
      runHook postPatch
    '';
  });

  common = { pname, rootDir, installPhase ? "", withQt ? false }:
    stdenv.mkDerivation (finalAttrs: {
      inherit pname;
      version = windscribe_version;
      src = windscribe_src;
      patches = [
        # patch the various references to boost libraries in their cmakelists, otherwise build fails
        ./patches/0001-cmakelists-.a-s-to-.so-s.patch
        # a couple files reference various /u?int\d+_t/ types but never import the relevant headers.
        #  i assume they usually ended up being imported as a side effect of another header and so
        #  it just always happened to work and wasn't caught
        ./patches/0002-missing-cstdint-includes.patch
        # builds fail b/c qt's qAsConst is deprecated, so swap out all the calls to that for ones to
        #  std::as_const. there's probably multiple better ways of dealing with this (use correct qt
        #  version, ignore the deprecation warnings(?)), but hey it works
        # done via:
        # grep -rl qAsConst . | xargs sed -i '1s/^/#include <utility>\n/;s/qAsConst/std::as_const/g'
        ./patches/0003-qasconst-to-std-as_const.patch
        # various changes i'd made but hadn't grouped into a patch yet
        ./patches/9999-uncommitted.patch
      ];
      nativeBuildInputs = [ cmake ]
        ++ lib.optionals withQt [ qt6.wrapQtAppsHook ];
      buildInputs = [ boost c-ares custom_openssl_ech_draft wireguard-tools custom_curl ]
        ++ lib.optionals withQt (with qt6; [ qtbase qt5compat qttools qtsvg ]);
      env.CXXFLAGS = "-fpermissive";
      # (using a cd here rather than setting sourceRoot since we want to always apply the patches relative to the top level)
      postPatch = ''
        cd "${rootDir}"
      '';
      inherit installPhase;
      dontFixup = true;
    });

  windscribe_cli = common {
    pname = "windscribe-cli";
    rootDir = "gui/cli";
    withQt = true;
    installPhase = ''
      mkdir -p $out/opt/windscribe
      cp windscribe-cli $out/opt/windscribe/
    '';
  };

  windscribe_helper = common {
    pname = "windscribe-helper";
    rootDir = "backend/linux/helper";
    installPhase = ''
      mkdir -p $out/opt/windscribe
      cp helper $out/opt/windscribe
    '';
  };

  windscribe_auth_helper = common {
    pname = "windscribe-authhelper";
    rootDir = "gui/authhelper/linux";
    installPhase = ''
      mkdir -p $out/opt/windscribe
      cp windscribe-authhelper $out/opt/windscribe
    '';
  };

  windscribe_client = (common {
    pname = "windscribe-client";
    rootDir = "client";
    withQt = true;
    installPhase = ''
      mkdir -p $out/opt/windscribe
      mkdir -p $out/bin
      cp Windscribe $out/opt/windscribe
      # ln -s $out/opt/windscribe/Windscribe $out/bin/windscribe
    '';
  }).overrideAttrs(finalAttrs: prevAttrs: {
  });

  # (bodging this together as multiple derivations that then get merged together, no idea if that's
  #  a good way of doing this but it works for now and also it means i don't need to wait thru a
  #  bunch of rebuilding every time i tweak something)
  # was doing this thru symlinkJoin, but when windscribe looks for the other executables it calls out to
  #  it looks past symlinks (e.g. basically `$(dirname $(readlink -f $0))/windscribeopenvpn`)
  windscribe_full = stdenv.mkDerivation (finalAttrs: {
    pname = "windscribe";
    version = windscribe_version;

    buildInputs = [
      windscribe_client
      windscribe_auth_helper
      windscribe_helper
      windscribe_cli
      custom_openvpn
      windscribewstunnel
      # custom_openssl
      # custom_curl
    ];

    runtimeDependencies = [
      custom_curl
      custom_openssl_ech_draft
      wireguard-tools  # ?
    ];

    dontWrapQtApps = true;

    # disable all the phases we don't use
    dontUnpack = true;
    dontPatch = true;
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      mkdir -p $out/bin
      mkdir -p $out/opt/windscribe

      cp ${windscribe_client}/opt/windscribe/Windscribe $out/opt/windscribe/Windscribe
      ln -s $out/opt/windscribe/Windscribe $out/bin/windscribe

      cp ${windscribe_auth_helper}/opt/windscribe/windscribe-authhelper $out/opt/windscribe/windscribe-authhelper

      cp ${windscribe_helper}/opt/windscribe/helper $out/opt/windscribe/helper

      cp ${windscribe_cli}/opt/windscribe/windscribe-cli $out/opt/windscribe/windscribe-cli

      cp ${custom_openvpn}/opt/windscribe/windscribeopenvpn $out/opt/windscribe/windscribeopenvpn

      cp ${windscribewstunnel}/opt/windscribe/windscribewstunnel $out/opt/windscribe/windscribewstunnel
    '';
  });

in

  windscribe_full



