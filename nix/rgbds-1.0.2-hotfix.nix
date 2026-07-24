{
  stdenv,
  lib,
  fetchFromGitHub,
  bison,
  flex,
  pkg-config,
  libpng,
}:

stdenv.mkDerivation {
  pname = "rgbds";
  version = "1.0.2+hotfix";

  src = fetchFromGitHub {
    owner = "gbdev";
    repo = "rgbds";
    rev = "3b1606c63c1671fd6675747507fe95d7f72da2d9";
    hash = "sha256-+f+fQDQPTFWmX6szB3wWixQ0VhQr37J4QPNvTKaspFg=";
  };

  nativeBuildInputs = [
    bison
    flex
    pkg-config
  ];

  buildInputs = [ libpng ];

  makeFlags = [ "PREFIX=$(out)" ];

  enableParallelBuilding = true;

  meta = {
    description = "Rednex Game Boy Development System";
    homepage = "https://rgbds.gbdev.io/";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
