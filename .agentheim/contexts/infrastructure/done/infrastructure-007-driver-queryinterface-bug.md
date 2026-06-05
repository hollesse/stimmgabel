---
id: infrastructure-007
title: Bug — StimmgabelDriver QueryInterface memcmp compares stack pointer instead of UUID bytes
status: done
type: bug
context: infrastructure
created: 2026-06-05
completed: 2026-06-05
commit:
depends_on: [infrastructure-006]
blocks: []
tags: [driver, coreaudio, audio-server-plugin, queryinterface]
related_adrs: [0005]
related_research: []
prior_art: [infrastructure-006]
---

## Why
Q1 empirical test from the walking skeleton (infrastructure-006) showed the Stimmgabel virtual device does not appear in Audio MIDI Setup on macOS 26.3. Console logs showed `HALS_UCPlugIn::ObjectGetPropertyData: the object is not valid` — coreaudiod loaded the driver in its UC process but immediately marked it invalid.

## Root cause
`StimmgabelDriver.c` line 148:
```c
// WRONG — compares 16 bytes starting at the address of the local pointer on the stack:
if (memcmp(&inUUID, kInterfaceBytes, 16) == 0)
```
`REFIID` / `CFUUIDRef` is a pointer. `&inUUID` is the address of that pointer variable on the stack — not the UUID bytes themselves. `QueryInterface` therefore always returns `E_NOINTERFACE`, so `coreaudiod` never acquires the driver interface.

## Fix
```c
CFUUIDBytes bytes = CFUUIDGetUUIDBytes(inUUID);
if (memcmp(&bytes, kInterfaceBytes, sizeof(bytes)) == 0)
```

## Acceptance criteria
- [ ] `codesign --verify --verbose /Library/Audio/Plug-Ins/HAL/Stimmgabel.driver` exits 0.
- [ ] After reinstalling (`script/install-driver.sh`), "Stimmgabel" input device appears in Audio MIDI Setup.
- [ ] No new `HALS_UCPlugIn: the object is not valid` errors in Console for `coreaudiod`.

## Outcome
Fixed in place — one-line change to `App/StimmgabelDriver/StimmgabelDriver.c`.
Q1 empirical answer updated in infrastructure README: ad-hoc signing loads correctly once `QueryInterface` returns the right interface.
