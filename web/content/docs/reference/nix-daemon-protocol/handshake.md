---
title: Handshake
slug: handshake
description: ""
summary: ""
date: 2025-03-24T13:10:37+02:00
lastmod: 2025-03-24T13:10:37+02:00
draft: false
weight: 51
toc: true
---

When connecting, the handshake sequence documented below must be performed, so
client and server can agree on a protocol version to use and exchange some
parameters.

## client -> server
- 0x6e697863 :: [Int](#se-Int) (hardcoded, 'nixc' in ASCII)

## client <- server
- 0x6478696f :: [Int](#se-Int) (hardcoded, 'dxio' in ASCII)
- protocolVersion :: [Int](#se-Int)

## client -> server
- clientVersion :: [Int](#se-Int)

### If clientVersion is 1.14 or later
- sendCpu :: [Bool](#se-Bool) (hardcoded to false in client)
#### If sendCpu is true
- cpuAffinity :: [Int](#se-Int) (obsolete and ignored)

### If clientVersion is 1.11 or later
- reserveSpace :: [Bool](#se-Bool) (obsolete, ignored and set to false)


## client <- server

### If clientVersion is 1.33 or later
- nixVersion :: String

### If clientVersion is 1.35 or later
- trusted :: OptTrusted

## client <- server
- send logs
- [operation]({{< relref "operations.md" >}}) :: [Int](#se-Int)

[se-Int]: {{< relref "types.md" >}}#int
[se-Bool]: {{< relref "types.md" >}}#bool
