package main

import (
	"encoding/binary"
	"errors"
	"fmt"
)

// Decode only the self-relative descriptor and simple ACE forms accepted by
// the Windows state guard. Never copy an unrestricted Linux-created template.
func trustedSID(data []byte) bool {
	if len(data) < 8 || data[0] != 1 || data[1] > 15 {
		return false
	}
	n := int(data[1])
	if len(data) < 8+4*n {
		return false
	}
	if data[2] != 0 || data[3] != 0 || data[4] != 0 || data[5] != 0 || data[6] != 0 || data[7] != 5 {
		return false
	}
	if n == 1 {
		return binary.LittleEndian.Uint32(data[8:]) == 18
	}
	return n == 2 && binary.LittleEndian.Uint32(data[8:]) == 32 && binary.LittleEndian.Uint32(data[12:]) == 544
}
func validateDescriptor(sd []byte) error {
	if len(sd) < 20 || sd[0] != 1 {
		return errors.New("invalid security descriptor")
	}
	control := binary.LittleEndian.Uint16(sd[2:])
	if control&0x8004 != 0x8004 {
		return errors.New("descriptor needs a self-relative DACL")
	}
	owner := int(binary.LittleEndian.Uint32(sd[4:]))
	if owner < 20 || owner >= len(sd) || !trustedSID(sd[owner:]) {
		return errors.New("descriptor owner is not SYSTEM or Administrators")
	}
	group := int(binary.LittleEndian.Uint32(sd[8:]))
	if group != 0 && (group < 20 || group+8 > len(sd) || sd[group] != 1 || int(sd[group+1]) > 15 || group+8+4*int(sd[group+1]) > len(sd)) {
		return errors.New("invalid group SID")
	}
	offset := int(binary.LittleEndian.Uint32(sd[16:]))
	if offset < 20 || offset+8 > len(sd) {
		return errors.New("missing or invalid DACL")
	}
	acl := sd[offset:]
	size := int(binary.LittleEndian.Uint16(acl[2:]))
	if size < 8 || size > len(acl) {
		return errors.New("invalid DACL size")
	}
	acl = acl[:size]
	count := int(binary.LittleEndian.Uint16(acl[4:]))
	pos := 8
	const mutation = uint32(0x10000000 | 0x40000000 | 0x40000 | 0x80000 | 0x10000 | 0x40 | 0x2 | 0x4 | 0x10 | 0x100)
	for i := 0; i < count; i++ {
		if pos+8 > len(acl) {
			return errors.New("truncated ACE")
		}
		ace := acl[pos:]
		length := int(binary.LittleEndian.Uint16(ace[2:]))
		if length < 16 || pos+length > len(acl) {
			return errors.New("invalid ACE size")
		}
		ace = ace[:length]
		switch ace[0] {
		case 1: // deny cannot broaden rights
		case 0:
			if binary.LittleEndian.Uint32(ace[4:])&mutation != 0 && !trustedSID(ace[8:]) {
				return errors.New("DACL grants mutation rights to an untrusted SID")
			}
		default:
			return fmt.Errorf("unsupported ACE type %d", ace[0])
		}
		pos += length
	}
	return nil
}
