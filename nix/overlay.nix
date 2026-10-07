final: prev:
let
  forcePushPatches = [
    ./patches/001-disable-force-push.patch
    ./patches/002-disable-force-with-lease-and-plus-refspec.patch
  ];
  withoutForcePush = git: git.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ forcePushPatches;
    doCheck = false;
    doInstallCheck = false;
    passthru = (old.passthru or { }) // { inherit forcePushPatches; };
  });
in
{
  git = withoutForcePush prev.git;
  gitMinimal = prev.git.override {
    withManual = false;
    osxkeychainSupport = false;
    pythonSupport = false;
    perlSupport = false;
    rustSupport = false;
    withpcre2 = false;
  };
}
