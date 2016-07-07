# Package

version       = "0.1.0"
author        = "Federico Ceratto"
description   = "A simple 2D racing game inspired by MicroMachines"
license       = "GPLv3"

# Dependencies

requires "nim >= 0.14.2"

task release, "Build a release":
  exec "nim c -d:release nimachine.nim"

task compressed, "Build a compressed, self-contained release":
  exec "nim c -d:release -d:embedData nimachine.nim"
  exec "upx-ucl -qq -9 ./nimachine"
