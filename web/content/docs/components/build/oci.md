---
title: "OCI Builder"
slug: oci
description: ""
summary: ""
date: 2023-09-07T16:12:37+02:00
lastmod: 2023-09-07T16:12:37+02:00
draft: false
weight: 42
toc: true
sidebar:
  collapsed: true
---

The OCI builder creates a OCI Runtime specification out of the received
`BuildRequest`, then mounts the specified inputs using snix-castore, and then
invokes `runc`.
