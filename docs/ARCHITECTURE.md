# Architecture: VRChat Spout → macOS Syphon → OBS, with DXMT kept intact

## What the stack actually is (verified in this environment)

```
VRChat (Windows, x86-64, under FEX)
  └─ d3d11.dll / dxgi.dll  = DXMT (guest-side PE, copied into the 438100 prefix by steamac's steam-gfx-path)
       └─ winemetal.dll → winemetal.so (Wine unixlib, x86-64) → wmtr client
            └─ virtio-gpu capset 30 (WMTR_CAPSET_ID) EXECBUFFER → steamac-vm process on macOS
                 └─ libwmtr_host.dylib  = the wmtr host executor + DXMT's winemetal_unix.c
                      └─ real Metal (Apple M5)
```

So every D3D11 object of the guest — including its textures — is a **real Metal object living in the
`steamac-vm` process on macOS**. The virtual GPU never copies guest textures to the host as pixels; the
host *is* the GPU client. This is the key fact the whole design rests on.

Evidence:
* `lsof -p <steamac-vm>` → `libwmtr_host.dylib` mapped in the VMM process.
* VRChat log: `[AVProMovieCapture] ... GPU Apple M5 Direct3D 11.0 [level 11.1]`; VRChat process maps
  `KlakSpout.dll`; prefix `system32/d3d11.dll` is DXMT's 4,681,728-byte dll.
* `wmtr/include/wmtr_host.h`: "The Mach ports stay in this process: every client's executor runs here."
* `dxmt/src/winemetal/unix/winemetal_unix.c:2721-2729` (pin `e94c312f`):
  `[device newSharedTextureWithDescriptor:]` → `[tex newSharedTextureHandle]` → `createMachPort`.

## Why not the other paths

| Path | Verdict |
| --- | --- |
| Windows OBS + obs-spout2-plugin inside the guest | Not the goal (needs native macOS OBS); the plugin is Windows/D3D11-only. |
| `spout2pw` (Spout→PipeWire) | Archived 2026-03; DXVK/Vulkan/DMA-BUF/PipeWire-only, x86-64 only, needs a patched Proton. No DXMT or macOS path. |
| Guest-side Spout receiver + socket/encode to macOS | Works in principle (`OpenSharedResource` exists in DXMT) but needs a full guest readback (FEX-emulated 3.6 MB/frame) plus a 110 MB/s transport, and adds latency. Rejected on cost, kept as fallback. |
| Copy the Spout Mach port out to a helper process | The wmtr executor keeps an **in-process** name table instead of the bootstrap server (`wmtr_host.m:505-512`), so a native helper cannot resolve it. Only works in-process. |
| Window capture of the game / OBS inside the VM | Explicitly a fallback only: not the independent camera view, and loses alpha. |

## The chosen seam

A Spout sender creates `D3D11_RESOURCE_MISC_SHARED` + `IDXGIResource::GetSharedHandle` — that is exactly
what VRChat's KlakSpout does (verified in the shipped `KlakSpout.dll`: `MISC_SHARED` path, `SpoutSenderNames`
shared memory, legacy handle; no `IDXGIResource1`/NT-handle imports). DXMT turns that into a Metal
**shared texture** through one Metal call: `-[MTLDevice newSharedTextureWithDescriptor:]`.

`libSpoutSyphon.dylib` is injected into `steamac-vm` (the launcher's main executable) with
`DYLD_INSERT_LIBRARIES`. It:

1. swizzles `newSharedTextureWithDescriptor:` on the concrete `MTLDevice` classes,
2. records every texture created that way (size/format filter, newest wins),
3. publishes it at a fixed rate through `SyphonMetalServer` (Syphon 5, the version OBS 33 bundles).

Nothing in the guest, in VRChat, in the Proton prefix, or in the launcher bundle is modified. OBS's stock
`mac-syphon` source lists the resulting server system-wide.

```
VRChat camera (Spout Stream)
  └─ D3D11 MISC_SHARED texture ──DXMT──► MTLSharedTexture (IOSurface-backed)   [steamac-vm process]
        └─ libSpoutSyphon.dylib: newSharedTextureWithDescriptor: hook
             └─ SyphonMetalServer (blit into Syphon's IOSurface pool)
                  └─ OBS 33 mac-syphon source  (SyphonServerDirectory → IOSurface → texture)
```

Cost per frame: one GPU blit inside the VM process + Syphon's copy into its IOSurface pool. No guest CPU
work, no readback, no encode, no network hop.

### Why Syphon and not a custom OBS plugin

OBS 33 already ships `mac-syphon.plugin` + `Syphon.framework`; publishing a Syphon server needs no OBS
change and no plugin build. The task asks to prefer the built-in path.

## Known limits of this seam

* Only textures created through `newSharedTextureWithDescriptor:` are visible. DXMT uses it exactly for
  `MISC_SHARED`/`MISC_SHARED_KEYEDMUTEX`/`NTHANDLE` textures, which is what Spout needs; the swapchain
  backbuffer and `CAMetalDrawable` are *not* shared textures (so this cannot accidentally publish the game
  window instead of the camera — but it also means window capture would need another mechanism).
* Syphon's Metal server copies; there is no zero-copy publish API. At 1280×720 this is one blit per frame.
* The publish rate is capped by `SPOUTSYPHON_FPS` (default 30), independent of the guest's frame rate.
* If VRChat recreates the sender (resolution change, camera close/open), the hook picks the new texture up
  automatically; the Syphon server stays the same and resizes.
