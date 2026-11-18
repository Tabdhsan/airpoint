# AirPoint wire protocol (v1)

UDP, port **47800** on the TV device, advertised over DNS-SD as `_airpoint._udp`.
All integers and floats are little-endian.

## Header (12 bytes, phone → TV)

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 2 | Magic `0x41 0x50` (`"AP"`) |
| 2 | 1 | Version `1` |
| 3 | 1 | Type |
| 4 | 4 | Session id (random per phone-app launch) |
| 8 | 4 | Sequence number (increments per packet) |

## Types

| Type | Name | Payload | Delivery |
| --- | --- | --- | --- |
| 1 | MOVE | `f32 dx, f32 dy` in pixels of a 1920×1080 reference screen | best effort |
| 2 | TAP | — | sent 3×, deduplicated by (session, seq) |
| 3 | LONG_PRESS | — | sent 3×, deduplicated |
| 4 | SCROLL | `f32 dx, f32 dy` finger travel in reference pixels | best effort |
| 5 | ACTION | `u8 code` | sent 3×, deduplicated |
| 6 | HELLO | `u8 flags` (bit 0: phone has a paired TV-remote session) | sent every second |
| 7 | POSITION | `f32 x, f32 y` absolute pointer position, 0…1 of the screen (Aim mode) | best effort |

Action codes: 1 Back, 2 Home, 3 Play/Pause, 10 D-pad up, 11 down, 12 left, 13 right, 14 center, 20 recenter pointer.

## Reply (TV → phone)

`"AP"`, version `1`, type `0x80`, `u16 width`, `u16 height`, `u8 flags` (bit 0: audio or video is
playing), then the device name as UTF-8.
Sent in response to every HELLO. The phone treats the link as connected while replies keep arriving.

## Key request (TV → phone)

`"AP"`, version `1`, type `0x81`, `u16 keycode`, `u32 request id`. Sent (twice) when the TV wants a
real remote key, currently only OK (`23`, DPAD_CENTER), and only while the phone's HELLO carries
flag bit 0 (`u8 flags` after the header = "paired remote session ready"). The phone sends the key
through the Android TV Remote v2 protocol, which some apps require instead of accessibility actions,
and ignores repeated request ids.

## Security

There is no pairing, authentication or encryption. Any host on the local network can move the
pointer and tap. Use only on a trusted network.
