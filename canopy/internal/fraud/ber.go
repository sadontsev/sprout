package fraud

import (
	"errors"
	"fmt"
)

// A minimal BER reader, because Apple's receipts are not DER.
//
// Go's encoding/asn1 is DER-only and says so. Apple's App Attest receipts — like App Store receipts
// — are CMS SignedData emitted in BER, and they use two constructs DER forbids:
//
//  1. INDEFINITE LENGTHS. A real receipt begins `30 80`: SEQUENCE, length-not-stated, terminated by
//     an end-of-contents marker. asn1.Unmarshal rejects the first byte pair outright with
//     "indefinite length found (not DER)".
//  2. CONSTRUCTED OCTET STRINGS. The encapsulated content is split into segments that must be
//     concatenated to recover the payload; DER requires one primitive string.
//
// Both were found by feeding a receipt captured from real hardware to the DER parser this package
// shipped with. It failed on the very first statement, which meant the fraud metric would have been
// silently unavailable forever: the sweep reads ErrMalformed as "this receipt is unreadable",
// defers the key a day, and does it again tomorrow. Every device would have stayed unassessed while
// the logs claimed only that redemption was failing.
//
// This handles exactly the subset a receipt needs. It is not a general BER implementation and
// should not become one.

var errBER = errors.New("ber: malformed")

// berElement is one tag-length-value.
type berElement struct {
	class       int
	tag         int
	constructed bool
	// content is the element's contents, with any indefinite-length framing and constructed-string
	// segmentation already resolved.
	content []byte
}

// berParse reads one element from b and returns it with the remaining bytes.
func berParse(b []byte) (berElement, []byte, error) {
	if len(b) < 2 {
		return berElement{}, nil, fmt.Errorf("%w: truncated header", errBER)
	}

	first := b[0]
	el := berElement{
		class:       int(first >> 6),
		constructed: first&0x20 != 0,
		tag:         int(first & 0x1f),
	}
	i := 1

	// High-tag-number form: 0x1f means the tag continues in subsequent bytes.
	if el.tag == 0x1f {
		el.tag = 0
		for {
			if i >= len(b) {
				return berElement{}, nil, fmt.Errorf("%w: truncated tag", errBER)
			}
			el.tag = el.tag<<7 | int(b[i]&0x7f)
			more := b[i]&0x80 != 0
			i++
			if !more {
				break
			}
		}
	}

	if i >= len(b) {
		return berElement{}, nil, fmt.Errorf("%w: truncated length", errBER)
	}
	lengthByte := b[i]
	i++

	switch {
	case lengthByte == 0x80:
		// Indefinite: contents run until a matching end-of-contents (00 00) at this nesting depth.
		// Only a constructed element may use it.
		if !el.constructed {
			return berElement{}, nil, fmt.Errorf("%w: indefinite length on a primitive", errBER)
		}
		content, rest, err := berScanIndefinite(b[i:])
		if err != nil {
			return berElement{}, nil, err
		}
		el.content = content
		return el, rest, nil

	case lengthByte < 0x80:
		// Short form: the byte is the length.
		n := int(lengthByte)
		if n > len(b)-i {
			return berElement{}, nil, fmt.Errorf("%w: length %d exceeds %d remaining", errBER, n, len(b)-i)
		}
		el.content = b[i : i+n]
		return el, b[i+n:], nil

	default:
		// Long form: the low bits say how many bytes carry the length.
		count := int(lengthByte & 0x7f)
		if count > 8 || count > len(b)-i {
			return berElement{}, nil, fmt.Errorf("%w: unsupported length-of-length %d", errBER, count)
		}
		n := 0
		for _, c := range b[i : i+count] {
			n = n<<8 | int(c)
		}
		i += count
		if n < 0 || n > len(b)-i {
			return berElement{}, nil, fmt.Errorf("%w: length %d exceeds %d remaining", errBER, n, len(b)-i)
		}
		el.content = b[i : i+n]
		return el, b[i+n:], nil
	}
}

// berScanIndefinite walks elements until the end-of-contents marker that closes the current one,
// returning the contents between and whatever follows.
func berScanIndefinite(b []byte) (content, rest []byte, err error) {
	consumed := 0
	for {
		if consumed+2 > len(b) {
			return nil, nil, fmt.Errorf("%w: unterminated indefinite length", errBER)
		}
		if b[consumed] == 0x00 && b[consumed+1] == 0x00 {
			return b[:consumed], b[consumed+2:], nil
		}
		_, after, err := berParse(b[consumed:])
		if err != nil {
			return nil, nil, err
		}
		consumed = len(b) - len(after)
	}
}

// berChildren splits a constructed element's contents into its elements.
func berChildren(content []byte) ([]berElement, error) {
	var out []berElement
	rest := content
	for len(rest) > 0 {
		// A stray end-of-contents can appear when a caller hands us contents that still carry one.
		if len(rest) >= 2 && rest[0] == 0x00 && rest[1] == 0x00 {
			rest = rest[2:]
			continue
		}
		el, after, err := berParse(rest)
		if err != nil {
			return nil, err
		}
		out = append(out, el)
		rest = after
	}
	return out, nil
}

// berOctets returns an OCTET STRING's bytes, concatenating the segments of a constructed one.
//
// This is the second thing DER forbids and Apple does: the encapsulated content of a receipt is
// split across segments, and reading only the first yields a truncated payload that then fails to
// parse in a way that looks like a different bug entirely.
func berOctets(el berElement) ([]byte, error) {
	if !el.constructed {
		return el.content, nil
	}
	kids, err := berChildren(el.content)
	if err != nil {
		return nil, err
	}
	var out []byte
	for _, k := range kids {
		segment, err := berOctets(k)
		if err != nil {
			return nil, err
		}
		out = append(out, segment...)
	}
	return out, nil
}

// berFind returns the first child with the given class and tag.
func berFind(kids []berElement, class, tag int) (berElement, bool) {
	for _, k := range kids {
		if k.class == class && k.tag == tag {
			return k, true
		}
	}
	return berElement{}, false
}

// ASN.1 universal tags this file needs.
const (
	tagInteger     = 0x02
	tagOctetString = 0x04
	tagSequence    = 0x10
	tagSet         = 0x11
)
