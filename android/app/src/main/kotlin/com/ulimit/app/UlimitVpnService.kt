package com.ulimit.app

import android.net.VpnService

/// Grants the permission surface the onboarding screen checks
/// (VpnService.prepare/hasVpnPermission) and gives the system something
/// real to bind to. The actual local-filtering logic — establishing the
/// TUN interface, routing selected apps' traffic through it, DNS-based
/// domain blocking — is a substantial feature on its own (see the
/// Internet & Sites mockup) and is the next slice, not this one.
///
/// Critically: even once implemented, this stays a *local* VPN — no
/// remote server, no traffic leaving the device. VpnService is Android's
/// sanctioned API for exactly this on-device-filter pattern; it's not
/// being used as a proxy.
class UlimitVpnService : VpnService()
