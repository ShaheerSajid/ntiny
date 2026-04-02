# ntiny platform build configuration for OpenSBI

platform-cppflags-y =
platform-cflags-y = -fno-stack-protector
platform-asflags-y =
platform-ldflags-y =

# Platform source
platform-objs-y += platform.o

# Firmware: jump mode (OpenSBI boots, then jumps to kernel at fixed address)
# For RV32: kernel at OpenSBI + 4MB offset = 0x80400000
FW_JUMP=y
FW_JUMP_ADDR=0x80400000
FW_JUMP_FDT_ADDR=0x80800000

# Also build dynamic and payload firmware
FW_DYNAMIC=y
FW_PAYLOAD=y
FW_PAYLOAD_OFFSET=0x400000
FW_PAYLOAD_FDT_OFFSET=0x2200000
