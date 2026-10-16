.code16
.global _start
_start:
  cli
  xor %ax, %ax
  mov %ax, %ds
  mov %ax, %ss
  mov $0x7c00, %sp
  mov $0x3fb, %dx
  mov $0x80, %al
  out %al, %dx
  mov $0x3f8, %dx
  mov $1, %al
  out %al, %dx
  inc %dx
  xor %al, %al
  out %al, %dx
  mov $0x3fb, %dx
  mov $3, %al
  out %al, %dx
  mov $message, %si
next:
  lodsb
  test %al, %al
  jz done
  mov $0x3f8, %dx
  out %al, %dx
  jmp next
done:
  hlt
  jmp done
message:
  .asciz "WOOTC_WHPX_BOOTSECTOR_EXECUTED\r\n"
.org 510
.word 0xaa55
