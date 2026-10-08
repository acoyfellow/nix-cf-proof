final: prev:
let
  forcePushPatches = [ ./patches/refuse-forced-ref-updates.patch ];
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
