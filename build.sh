#!/bin/sh

# zig build-exe -fsingle-threaded main.zig "$@"

zig build-exe -OReleaseSmall -fsingle-threaded -flto -fstrip main.zig