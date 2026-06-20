cd /d C:\Sadirano\repo\owl\nix
  rem Portable build: -Dcpu=baseline avoids baking the dev machine's CPU
  rem extensions into the binary. A native build (the default) crashes with an
  rem illegal instruction on any machine whose CPU lacks those extensions --
  rem this is what broke the Scoop-bucket install on a fresh machine.
  zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows -Dcpu=baseline
  zig-out\bin\nix.exe --sync
