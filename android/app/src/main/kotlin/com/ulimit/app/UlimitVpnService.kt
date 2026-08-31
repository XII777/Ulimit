package com.ulimit.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.Closeable
import java.io.FileInputStream
import java.io.File
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Local, on-device VPN. No remote server exists; traffic never leaves
 * the device through Ulimit. Two modes, chosen from the snapshot:
 *
 *  FIREWALL MODE — per-app internet blocking.
 *    Only the blocked apps are routed into the TUN (addAllowedApplication);
 *    every packet they send is discarded, so they lose connectivity
 *    completely (including hardcoded DNS). Everyone else bypasses the TUN.
 *
 *  FILTER MODE — website/domain blocking.
 *    No app filter is applied; instead only DNS reaches the TUN (the
 *    virtual DNS server is reachable only through it). DNS queries are
 *    parsed, names are matched against the blocked-domain set (exact or
 *    subdomain match), blocked ones are answered with 0.0.0.0, and
 *    everything else is forwarded to a real upstream resolver through a
 *    protect()-ed socket. DoH/DoT bypasses are a known, documented
 *    limitation of DNS-level filtering.
 *
 * Domain state is reloaded from filesDir/blocked_domains.txt on every
 * ACTION_RELOAD without tearing the tunnel down (Dart rewrites the file
 * atomically).
 */
class UlimitVpnService : VpnService() {

    companion object {
        const val ACTION_STOP = "com.ulimit.app.VPN_STOP"
        const val ACTION_RELOAD = "com.ulimit.app.VPN_RELOAD"
        const val CHANNEL_ID = "ulimit_vpn"

        // The virtual DNS server = the TUN interface address. Only a
        // /32 host route for this address enters the TUN, so DNS from
        // every app is capturable while their other traffic stays on
        // the real network.
        val DNS_SERVER: InetAddress = InetAddress.getByName("10.111.0.1")

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private var tun: ParcelFileDescriptor? = null
    private var worker: Thread? = null
    private val running = AtomicBoolean(false)
    private var blockedDomains: Set<String> = emptySet()
    private val upstreamSockets = ConcurrentLinkedQueue<Closeable>()

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Android requires startForeground() within ~5s of ANY
        // startForegroundService() call — including stop/reload intents.
        // Skipping it here (e.g. an ACTION_RELOAD while the service was
        // down) crashes with ForegroundServiceDidNotStartInTimeException.
        startAsForeground()

        when (intent?.action) {
            ACTION_STOP -> {
                stopEverything()
                return START_NOT_STICKY
            }
            ACTION_RELOAD -> {
                blockedDomains = loadBlockedDomains()
                return START_STICKY
            }
        }
        blockedDomains = loadBlockedDomains()
        establish()
        // START_STICKY: if the process is killed, the system restarts the
        // service and the tunnel is re-established from persisted state.
        return START_STICKY
    }

    private fun startAsForeground() {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent() // launch intent is never expected to be null for us; guard anyway
        val pending = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification: Notification
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val builder = android.app.Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("Ulimit")
                .setContentText("Network protection active")
                .setSmallIcon(android.R.drawable.ic_lock_lock)
                .setOngoing(true)
                .setContentIntent(pending)
            notification = builder.build()
        } else {
            @Suppress("DEPRECATION")
            notification = Notification.Builder(this)
                .setContentTitle("Ulimit")
                .setContentText("Network protection active")
                .setSmallIcon(android.R.drawable.ic_lock_lock)
                .setOngoing(true)
                .setContentIntent(pending)
                .build()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                1, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(1, notification)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "Network protection", NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "Local VPN filtering status"
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(channel)
        }
    }

    // ------------------------------------------------------------------
    // Tunnel setup
    // ------------------------------------------------------------------

    private fun establish() {
        stopWorker()

        val snapshot = PolicySnapshot.read(this)
        val now = System.currentTimeMillis()

        // Every app that must lose connectivity entirely. Focus and
        // bedtime internet policies fold into the same firewall set.
        val firewallApps = mutableListOf<String>()
        snapshot?.internetBlocks?.let { firewallApps.addAll(it) }
        snapshot?.focus?.let { focus ->
            if (focus.blockInternet && focus.untilMillis > now) firewallApps.addAll(focus.packages)
        }
        snapshot?.bedtime?.let { bedtime ->
            if (bedtime.blockInternet &&
                PolicySnapshot.inWindow(nowMinutes(), bedtime.startMinutes, bedtime.endMinutes)
            ) {
                firewallApps.addAll(bedtime.packages)
            }
        }

        val wantFiltering = hasFilterEntries()

        // Nothing to enforce on the network layer — don't occupy the
        // VPN slot doing nothing.
        if (firewallApps.isEmpty() && !wantFiltering) {
            isRunning = true
            return
        }

        // Unified capture model:
        //  - The virtual DNS server IS the TUN interface address, and
        //    a /32 host route is added for it — so ONLY DNS traffic
        //    enters the TUN. Every other packet stays on the real
        //    network (no default-route capture; Android would otherwise
        //    install 0.0.0.0/0 and the filter loop would drop all TCP,
        //    killing the whole internet).
        //  - Internet-blocked apps are allowlisted into the TUN in
        //    addition, so ALL their packets (DNS + TCP) are captured
        //    and discarded → they lose connectivity entirely while
        //    everyone else keeps it.
        val builder = Builder()
            .setSession("Ulimit")
            .setMtu(32767)
            .addAddress("10.111.0.1", 32)
            .addDnsServer("10.111.0.1")
            .addRoute("10.111.0.1", 32)

        for (pkg in firewallApps.distinct()) {
            try {
                builder.addAllowedApplication(pkg)
            } catch (e: Exception) {
                // Uninstalled package — skip it.
            }
        }

        val newTun = try {
            builder.establish()
        } catch (e: Exception) {
            Log.w("UlimitVpn", "establish failed", e)
            null
        }
        if (newTun == null) {
            isRunning = true // keep the foreground state visible; retry on reload
            return
        }
        tun = newTun
        isRunning = true
        running.set(true)

        val input = FileInputStream(newTun.fileDescriptor)
        val output = FileOutputStream(newTun.fileDescriptor)
        worker = Thread {
            try {
                if (wantFiltering) {
                    // Filter loop serves two purposes at once: DNS from
                    // every app is checked against the blocked-domain
                    // set, and any other packet (i.e. everything a
                    // firewall app sends) is dropped because it is never
                    // written back out.
                    dnsFilterLoop(input, output)
                } else {
                    // Firewall-only mode: discard everything routed in.
                    drainAndDiscard(input)
                }
            } catch (_: Exception) {
                // Tunnel torn down — expected on stop.
            }
        }.apply {
            name = "ulimit-vpn-loop"
            start()
        }
    }

    private fun nowMinutes(): Int {
        val c = java.util.Calendar.getInstance()
        return c.get(java.util.Calendar.HOUR_OF_DAY) * 60 + c.get(java.util.Calendar.MINUTE)
    }

    private fun hasFilterEntries(): Boolean {
        val file = File(filesDir, "blocked_domains.txt")
        return file.exists() && file.length() > 0
    }

    private fun loadBlockedDomains(): Set<String> {
        val file = File(filesDir, "blocked_domains.txt")
        if (!file.exists()) return emptySet()
        return try {
            file.readLines()
                .asSequence()
                .map { it.trim().lowercase() }
                .filter { it.isNotEmpty() }
                .toSet()
        } catch (_: Exception) {
            emptySet()
        }
    }

    // ------------------------------------------------------------------
    // Firewall mode: consume and discard everything routed to us.
    // ------------------------------------------------------------------

    private fun drainAndDiscard(input: FileInputStream) {
        val buffer = ByteArray(32767)
        while (running.get()) {
            val n = input.read(buffer)
            if (n < 0) break
            // Discard — blocked apps lose all connectivity.
        }
    }

    // ------------------------------------------------------------------
    // Filter mode: intercept UDP/53, block or forward DNS queries.
    // ------------------------------------------------------------------

    private fun dnsFilterLoop(input: FileInputStream, output: FileOutputStream) {
        val buffer = ByteArray(32767)
        val upstreamDns = arrayOf("1.1.1.1", "8.8.8.8")

        while (running.get()) {
            val n = input.read(buffer)
            if (n < 0) break
            if (n < 28) continue // smaller than IPv4+UDP headers

            val version = (buffer[0].toInt() shr 4) and 0xF
            if (version != 4) continue // IPv6 never enters this TUN

            val ihl = (buffer[0].toInt() and 0xF) * 4
            val protocol = buffer[9].toInt() and 0xFF
            if (protocol != 17) continue // UDP only; TCP DNS is rare and retried over UDP

            val srcAddr = InetAddress.getByAddress(buffer.copyOfRange(12, 16))
            val udpStart = ihl
            val srcPort = ((buffer[udpStart].toInt() and 0xFF) shl 8) or (buffer[udpStart + 1].toInt() and 0xFF)
            val dstPort = ((buffer[udpStart + 2].toInt() and 0xFF) shl 8) or (buffer[udpStart + 3].toInt() and 0xFF)
            if (dstPort != 53) continue // only DNS

            val udpLen = ((buffer[udpStart + 4].toInt() and 0xFF) shl 8) or (buffer[udpStart + 5].toInt() and 0xFF)
            val dnsLen = udpLen - 8
            if (dnsLen < 12) continue
            val dnsOffset = udpStart + 8
            val dnsPacket = buffer.copyOfRange(dnsOffset, dnsOffset + dnsLen)

            val parsed = extractQName(dnsPacket) ?: continue
            val (qname, qEnd) = parsed
            val qtype = if (dnsPacket.size > qEnd + 3) {
                ((dnsPacket[qEnd + 2].toInt() and 0xFF) shl 8) or (dnsPacket[qEnd + 3].toInt() and 0xFF)
            } else 1

            if (isBlocked(qname)) {
                // Authoritative "no such host": respond with 0.0.0.0 for
                // A queries and an empty answer for everything else.
                val reply = buildBlockedReply(dnsPacket, qtype == 1)
                writeUdp(output, DNS_SERVER, 53, srcAddr, srcPort, reply)
            } else {
                forwardQuery(output, srcAddr, srcPort, dnsPacket, upstreamDns)
            }
        }
    }

    /** QNAME of the first question + the offset just past its type/class. */
    private fun extractQName(dns: ByteArray): Pair<String, Int>? {
        if (dns.size < 17) return null
        val sb = StringBuilder()
        var i = 12
        while (i < dns.size) {
            val len = dns[i].toInt() and 0xFF
            if (len == 0) break
            if (len > 63 || i + 1 + len > dns.size) return null
            if (sb.isNotEmpty()) sb.append('.')
            for (j in i + 1 until i + 1 + len) {
                sb.append((dns[j].toInt() and 0xFF).toChar())
            }
            i += 1 + len
        }
        if (i >= dns.size || dns[i].toInt() != 0) return null
        val nameEnd = i + 1 // past the terminating zero
        if (nameEnd + 4 > dns.size) return null
        return Pair(sb.toString().lowercase(), nameEnd + 4)
    }

    private fun isBlocked(qname: String): Boolean {
        if (blockedDomains.isEmpty()) return false
        if (qname in blockedDomains) return true
        var dot = qname.indexOf('.')
        while (dot > 0) {
            if (qname.substring(dot + 1) in blockedDomains) return true
            dot = qname.indexOf('.', dot + 1)
        }
        return false
    }

    /** Minimal DNS reply: question echoed, single A 0.0.0.0 (or empty). */
    private fun buildBlockedReply(query: ByteArray, withARecord: Boolean): ByteArray {
        val header = byteArrayOf(
            query[0], query[1],           // id
            (query[2].toInt() or 0x80).toByte(), // QR=1, keep RD
            0x81.toByte(),                 // RA=1 (0x81 overflows signed Byte)
            0, 1,                          // QDCOUNT=1
            ((if (withARecord) 0 else 0)).toByte(), ((if (withARecord) 1 else 0)).toByte(), // ANCOUNT
            0, 0, 0, 0                     // NSCOUNT / ARCOUNT
        )
        // Echo the question section verbatim (starts at 12, ends at first
        // zero byte + 4 bytes of type/class).
        var qEnd = 12
        while (qEnd < query.size && query[qEnd].toInt() != 0) {
            qEnd += (query[qEnd].toInt() and 0xFF) + 1
        }
        qEnd += 5 // zero byte + QTYPE(2) + QCLASS(2)
        val question = query.copyOfRange(12, minOf(qEnd, query.size))

        val answer = if (withARecord) byteArrayOf(
            0xC0.toByte(), 0x0C,           // pointer to question name
            0, 1,                          // TYPE A
            0, 1,                          // CLASS IN
            0, 0, 0, 0,                    // TTL 0
            0, 4,                          // RDLENGTH 4
            0, 0, 0, 0                     // 0.0.0.0
        ) else ByteArray(0)

        return header + question + answer
    }

    /**
     * Forwards a DNS query to a real resolver through a protect()-ed
     * socket and writes the response back into the TUN as if it came
     * from the virtual DNS server.
     */
    private fun forwardQuery(
        output: FileOutputStream,
        clientAddr: InetAddress,
        clientPort: Int,
        dnsQuery: ByteArray,
        upstreams: Array<String>
    ) {
        Thread {
            var socket: DatagramSocket? = null
            try {
                socket = DatagramSocket()
                protect(socket)
                upstreamSockets.add(socket)

                for (upstream in upstreams) {
                    try {
                        val addr = InetAddress.getByName(upstream)
                        socket.soTimeout = 4000
                        socket.send(DatagramPacket(dnsQuery, dnsQuery.size, InetSocketAddress(addr, 53)))

                        val buf = ByteArray(4096)
                        val reply = DatagramPacket(buf, buf.size)
                        socket.receive(reply)

                        // Rewrite the ID is unnecessary (query id is
                        // preserved by the resolver); wrap as UDP from
                        // the virtual DNS server — clients drop replies
                        // that appear to come from any other address.
                        writeUdp(output, DNS_SERVER, 53, clientAddr, clientPort, reply.data.copyOf(reply.length))
                        return@Thread
                    } catch (_: Exception) {
                        continue
                    }
                }
            } catch (_: Exception) {
            } finally {
                upstreamSockets.remove(socket)
                socket?.close()
            }
        }.apply {
            isDaemon = true
            name = "ulimit-dns-fwd"
            start()
        }
    }

    /** Writes one UDP packet (IPv4, no fragmentation) into the TUN. */
    private fun writeUdp(
        output: FileOutputStream,
        srcAddr: InetAddress,
        srcPort: Int,
        dstAddr: InetAddress,
        dstPort: Int,
        payload: ByteArray
    ) {
        val udpLen = 8 + payload.size
        val totalLen = 20 + udpLen
        val packet = ByteArray(totalLen)

        packet[0] = 0x45 // IPv4, IHL 5
        packet[1] = 0
        packet[2] = (totalLen shr 8).toByte()
        packet[3] = totalLen.toByte()
        packet[4] = 0; packet[5] = 0            // id
        packet[6] = 0x40; packet[7] = 0         // DF, offset
        packet[8] = 64                           // TTL
        packet[9] = 17                           // UDP
        // checksum computed below
        val src = srcAddr.address
        val dst = dstAddr.address
        System.arraycopy(src, 0, packet, 12, 4)
        System.arraycopy(dst, 0, packet, 16, 4)

        packet[20] = (srcPort shr 8).toByte()
        packet[21] = srcPort.toByte()
        packet[22] = (dstPort shr 8).toByte()
        packet[23] = dstPort.toByte()
        packet[24] = (udpLen shr 8).toByte()
        packet[25] = udpLen.toByte()
        // UDP checksum 0 is legal for IPv4 — skip computation.
        System.arraycopy(payload, 0, packet, 28, payload.size)

        // IP header checksum
        var sum = 0
        for (i in 0 until 20 step 2) {
            sum += ((packet[i].toInt() and 0xFF) shl 8) or (packet[i + 1].toInt() and 0xFF)
        }
        while (sum shr 16 > 0) sum = (sum and 0xFFFF) + (sum shr 16)
        val checksum = (sum.inv()) and 0xFFFF
        packet[10] = (checksum shr 8).toByte()
        packet[11] = checksum.toByte()

        try {
            output.write(packet)
            output.flush()
        } catch (_: Exception) {
        }
    }

    // ------------------------------------------------------------------
    // Teardown
    // ------------------------------------------------------------------

    private fun stopWorker() {
        running.set(false)
        worker?.join(500)
        worker = null
        tun?.close()
        tun = null
    }

    private fun stopEverything() {
        running.set(false)
        stopWorker()
        for (c in upstreamSockets) {
            try {
                c.close()
            } catch (_: Exception) {
            }
        }
        upstreamSockets.clear()
        isRunning = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onRevoke() {
        // The system (or another VPN) revoked us — reflect reality in
        // prefs so the UI and boot logic agree.
        PolicySnapshot.prefs(this).edit().putBoolean(PolicySnapshot.KEY_VPN_ENABLED, false).apply()
        stopEverything()
    }

    override fun onDestroy() {
        running.set(false)
        stopWorker()
        isRunning = false
        super.onDestroy()
    }
}
