package com.bitbyteco.airpoint;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.GestureDescription;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.util.Log;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityEvent;

import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetSocketAddress;
import java.net.SocketException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.HashSet;

/** Draws a pointer overlay and turns AirPoint packets into gestures and global actions. */
public class AirPointService extends AccessibilityService {
    static final String TAG = "AirPoint";
    static final int PORT = 47800;
    static final String SERVICE_TYPE = "_airpoint._udp";
    static final float REF_W = 1920f, REF_H = 1080f;
    static final long HIDE_AFTER_MS = 5000;

    static final int T_MOVE = 1, T_TAP = 2, T_LONG = 3, T_SCROLL = 4, T_ACTION = 5, T_HELLO = 6, T_POSITION = 7;

    /** Read by MainActivity for its status line. */
    static volatile String status = "Not running";
    static volatile long lastPacketAt = 0;
    static volatile String lastSender = "";

    private Handler main;
    private WindowManager wm;
    private CursorOverlay overlay;
    private int width, height;
    private float x, y;

    private DatagramSocket socket;
    private Thread receiver;
    private volatile boolean running;
    private NsdManager nsd;
    private NsdManager.RegistrationListener registration;
    private WifiManager.MulticastLock multicastLock;
    private String deviceName;
    private android.media.AudioManager audio;

    // Discrete packets arrive up to three times; remember recent (session, seq) keys.
    private final HashSet<Long> seen = new HashSet<>();
    private final ArrayDeque<Long> seenOrder = new ArrayDeque<>();

    private float pendingScrollX, pendingScrollY;
    private boolean gestureBusy;
    // The phone's address and whether it holds a paired TV-remote session (HELLO flag bit 0).
    private volatile java.net.SocketAddress phoneAddress;
    private volatile boolean phoneHasRemote;
    private volatile long phoneSeenAt;
    private int keyRequestId = (int) (System.currentTimeMillis() & 0x7FFFFFFF);
    private NodeInput nodes;
    private boolean touchGestures;   // device accepts injected touch (most TV boxes don't)
    private static final float SCROLL_STEP_PX = 140f;

    private final Runnable hideCursor = () -> overlay.setCursorVisible(false);

    @Override
    protected void onServiceConnected() {
        main = new Handler(Looper.getMainLooper());
        wm = getSystemService(WindowManager.class);
        // The window manager can report a scaled UI size (1280x720 on a 1080p panel); the overlay
        // and gestures use real pixels, so take the size from the overlay once it is laid out.
        Rect bounds = wm.getMaximumWindowMetrics().getBounds();
        width = bounds.width();
        height = bounds.height();
        x = width / 2f;
        y = height / 2f;

        audio = getSystemService(android.media.AudioManager.class);
        nodes = new NodeInput(this, this::pressCenter, () -> phoneHasRemote && System.currentTimeMillis() - phoneSeenAt < 3000);
        touchGestures = getPackageManager().hasSystemFeature("android.hardware.touchscreen")
                || getPackageManager().hasSystemFeature("android.hardware.faketouch");
        Log.i(TAG, "touch gestures " + (touchGestures ? "available" : "unavailable; using UI actions"));

        overlay = new CursorOverlay(this);
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        overlay.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or, ob) -> {
            if (r - l > 0 && b - t > 0 && (r - l != width || b - t != height)) {
                width = r - l;
                height = b - t;
                x = clamp(x, 0, width - 1);
                y = clamp(y, 0, height - 1);
                Log.i(TAG, "screen " + width + "x" + height);
            }
        });
        wm.addView(overlay, lp);
        overlay.moveCursor(x, y);
        overlay.setCursorVisible(false);

        deviceName = Settings.Global.getString(getContentResolver(), Settings.Global.DEVICE_NAME);
        if (deviceName == null || deviceName.isEmpty()) deviceName = Build.MODEL;

        startNetwork();
    }

    @Override public void onAccessibilityEvent(AccessibilityEvent event) { }
    @Override public void onInterrupt() { }

    @Override
    public void onDestroy() {
        stopNetwork();
        if (overlay != null && wm != null) {
            try { wm.removeView(overlay); } catch (Exception ignored) { }
        }
        status = "Not running";
        super.onDestroy();
    }

    // ---------------------------------------------------------------- network

    private void startNetwork() {
        running = true;
        try {
            socket = new DatagramSocket(null);
            socket.setReuseAddress(true);
            socket.bind(new InetSocketAddress(PORT));
        } catch (SocketException e) {
            status = "Could not open UDP port " + PORT + ": " + e.getMessage();
            Log.e(TAG, status, e);
            return;
        }
        receiver = new Thread(this::receiveLoop, "AirPoint-rx");
        receiver.start();

        WifiManager wifi = getApplicationContext().getSystemService(WifiManager.class);
        if (wifi != null) {
            multicastLock = wifi.createMulticastLock("AirPoint");
            multicastLock.setReferenceCounted(false);
            multicastLock.acquire();
        }

        nsd = getSystemService(NsdManager.class);
        NsdServiceInfo info = new NsdServiceInfo();
        info.setServiceName("AirPoint " + deviceName);
        info.setServiceType(SERVICE_TYPE);
        info.setPort(PORT);
        registration = new NsdManager.RegistrationListener() {
            @Override public void onServiceRegistered(NsdServiceInfo s) {
                status = "Waiting for phone (advertised as \"" + s.getServiceName() + "\")";
                Log.i(TAG, status);
            }
            @Override public void onRegistrationFailed(NsdServiceInfo s, int code) {
                status = "Bonjour registration failed (" + code + "); still listening on UDP " + PORT;
                Log.w(TAG, status);
            }
            @Override public void onServiceUnregistered(NsdServiceInfo s) { }
            @Override public void onUnregistrationFailed(NsdServiceInfo s, int code) { }
        };
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, registration);
        status = "Listening on UDP " + PORT;
    }

    private void stopNetwork() {
        running = false;
        if (nsd != null && registration != null) {
            try { nsd.unregisterService(registration); } catch (Exception ignored) { }
        }
        if (multicastLock != null && multicastLock.isHeld()) multicastLock.release();
        if (socket != null) socket.close();
    }

    private void receiveLoop() {
        byte[] buf = new byte[256];
        DatagramPacket packet = new DatagramPacket(buf, buf.length);
        byte[] nameBytes = deviceName.getBytes(StandardCharsets.UTF_8);
        while (running) {
            try {
                packet.setLength(buf.length);
                socket.receive(packet);
            } catch (Exception e) {
                if (running) Log.w(TAG, "receive failed", e);
                continue;
            }
            int len = packet.getLength();
            if (len < 12 || buf[0] != 0x41 || buf[1] != 0x50 || buf[2] != 1) continue;
            ByteBuffer b = ByteBuffer.wrap(buf, 0, len).order(ByteOrder.LITTLE_ENDIAN);
            int type = b.get(3) & 0xFF;
            long session = b.getInt(4) & 0xFFFFFFFFL;
            long seq = b.getInt(8) & 0xFFFFFFFFL;
            lastPacketAt = System.currentTimeMillis();
            lastSender = packet.getAddress().getHostAddress();

            if (type == T_HELLO) {
                phoneAddress = packet.getSocketAddress();
                phoneHasRemote = len >= 13 && (buf[12] & 1) != 0;
                phoneSeenAt = System.currentTimeMillis();
                // Flags: bit 0 = audio/video is playing (lets the phone show media controls).
                byte flags = (byte) (audio != null && audio.isMusicActive() ? 1 : 0);
                ByteBuffer reply = ByteBuffer.allocate(9 + nameBytes.length).order(ByteOrder.LITTLE_ENDIAN);
                reply.put((byte) 0x41).put((byte) 0x50).put((byte) 1).put((byte) 0x80);
                reply.putShort((short) width).putShort((short) height).put(flags).put(nameBytes);
                try {
                    socket.send(new DatagramPacket(reply.array(), reply.position(), packet.getSocketAddress()));
                } catch (Exception e) {
                    Log.w(TAG, "reply failed", e);
                }
                status = "Connected to phone at " + lastSender;
                continue;
            }

            final float fx = len >= 20 ? b.getFloat(12) : 0f;
            final float fy = len >= 20 ? b.getFloat(16) : 0f;
            final int code = len >= 13 ? b.get(12) & 0xFF : 0;
            if (type == T_TAP || type == T_LONG || type == T_ACTION) {
                if (!firstTime((session << 32) | seq)) continue;
            }
            main.post(() -> handle(type, fx, fy, code));
        }
    }

    private boolean firstTime(long key) {
        if (seen.contains(key)) return false;
        seen.add(key);
        seenOrder.addLast(key);
        if (seenOrder.size() > 128) seen.remove(seenOrder.removeFirst());
        return true;
    }

    // ---------------------------------------------------------------- input

    private void handle(int type, float fx, float fy, int code) {
        switch (type) {
            case T_MOVE:
                x = clamp(x + fx * width / REF_W, 0, width - 1);
                y = clamp(y + fy * height / REF_H, 0, height - 1);
                showCursor();
                break;
            case T_POSITION:
                x = clamp(fx * width, 0, width - 1);
                y = clamp(fy * height, 0, height - 1);
                showCursor();
                break;
            case T_TAP:
            case T_LONG: {
                showCursor();
                overlay.pulse();
                boolean longPress = type == T_LONG;
                boolean done = nodes.click(x, y, longPress);
                if (!done && touchGestures) tap(longPress ? 800 : 80);
                else if (!done) Log.i(TAG, "nothing clickable at " + x + "," + y);
                break;
            }
            case T_SCROLL:
                showCursor();
                pendingScrollX += fx * width / REF_W;
                pendingScrollY += fy * height / REF_H;
                if (touchGestures) flushScroll();
                else stepScroll();
                break;
            case T_ACTION:
                action(code);
                break;
        }
    }

    private void showCursor() {
        overlay.moveCursor(x, y);
        overlay.setCursorVisible(true);
        main.removeCallbacks(hideCursor);
        main.postDelayed(hideCursor, HIDE_AFTER_MS);
    }

    private void tap(long durationMs) {
        Path path = new Path();
        path.moveTo(x, y);
        path.lineTo(x + 0.5f, y + 0.5f);
        GestureDescription g = new GestureDescription.Builder()
                .addStroke(new GestureDescription.StrokeDescription(path, 0, durationMs))
                .build();
        pendingScrollX = pendingScrollY = 0;
        gestureBusy = true;
        boolean ok = dispatchGesture(g, gestureDone, main);
        Log.i(TAG, "tap at " + x + "," + y + " dispatched=" + ok);
    }

    private final GestureResultCallback gestureDone = new GestureResultCallback() {
        @Override public void onCompleted(GestureDescription g) { Log.i(TAG, "gesture completed"); gestureBusy = false; flushScroll(); }
        @Override public void onCancelled(GestureDescription g) { Log.i(TAG, "gesture cancelled"); gestureBusy = false; flushScroll(); }
    };

    /** Converts accumulated finger travel into discrete scroll steps on the container under the pointer. */
    private void stepScroll() {
        while (Math.abs(pendingScrollY) >= SCROLL_STEP_PX || Math.abs(pendingScrollX) >= SCROLL_STEP_PX) {
            if (Math.abs(pendingScrollY) >= Math.abs(pendingScrollX)) {
                int dir = pendingScrollY > 0 ? 1 : -1;
                pendingScrollY -= dir * SCROLL_STEP_PX;
                nodes.scroll(x, y, 0, dir);
            } else {
                int dir = pendingScrollX > 0 ? 1 : -1;
                pendingScrollX -= dir * SCROLL_STEP_PX;
                nodes.scroll(x, y, dir, 0);
            }
        }
    }

    /** Replays accumulated finger travel as one short swipe starting at the pointer. */
    private void flushScroll() {
        if (gestureBusy) return;
        float dx = pendingScrollX, dy = pendingScrollY;
        if (Math.hypot(dx, dy) < 6) return;
        pendingScrollX = pendingScrollY = 0;
        float sx = clamp(x, 1, width - 2), sy = clamp(y, 1, height - 2);
        float ex = clamp(sx + dx, 1, width - 2), ey = clamp(sy + dy, 1, height - 2);
        if (Math.hypot(ex - sx, ey - sy) < 2) return;
        Path path = new Path();
        path.moveTo(sx, sy);
        path.lineTo(ex, ey);
        GestureDescription g = new GestureDescription.Builder()
                .addStroke(new GestureDescription.StrokeDescription(path, 0, 120))
                .build();
        gestureBusy = true;
        dispatchGesture(g, gestureDone, main);
    }

    private void action(int code) {
        switch (code) {
            case 1: performGlobalAction(GLOBAL_ACTION_BACK); break;
            case 2: performGlobalAction(GLOBAL_ACTION_HOME); break;
            case 3: performGlobalAction(GLOBAL_ACTION_KEYCODE_HEADSETHOOK); break;
            case 10: performGlobalAction(GLOBAL_ACTION_DPAD_UP); break;
            case 11: performGlobalAction(GLOBAL_ACTION_DPAD_DOWN); break;
            case 12: performGlobalAction(GLOBAL_ACTION_DPAD_LEFT); break;
            case 13: performGlobalAction(GLOBAL_ACTION_DPAD_RIGHT); break;
            case 14:
                // OK: with the pointer on screen it clicks under the pointer; otherwise it's the remote's OK.
                if (overlay.isCursorVisible()) {
                    overlay.pulse();
                    if (!nodes.click(x, y, false) && touchGestures) tap(80);
                } else {
                    pressCenter();
                }
                break;
            case 21:   // hide pointer (phone switched to D-pad style navigation)
                main.removeCallbacks(hideCursor);
                overlay.setCursorVisible(false);
                break;
            case 20:
                x = width / 2f;
                y = height / 2f;
                showCursor();
                overlay.pulse();
                break;
        }
    }

    /** OK key: ask the phone to send a real remote key if it can, otherwise use the accessibility key. */
    void pressCenter() {
        java.net.SocketAddress addr = phoneAddress;
        if (phoneHasRemote && addr != null && System.currentTimeMillis() - phoneSeenAt < 3000) {
            // Key request: u16 keycode (DPAD_CENTER), u32 request id so the phone can drop the duplicate.
            int id = ++keyRequestId;
            byte[] msg = ByteBuffer.allocate(10).order(ByteOrder.LITTLE_ENDIAN)
                    .put((byte) 0x41).put((byte) 0x50).put((byte) 1).put((byte) 0x81)
                    .putShort((short) 23).putInt(id).array();
            new Thread(() -> {
                try {
                    for (int i = 0; i < 2; i++) socket.send(new DatagramPacket(msg, msg.length, addr));
                } catch (Exception e) {
                    Log.w(TAG, "key request failed", e);
                }
            }).start();
            Log.i(TAG, "asked phone for a real OK key");
        } else {
            performGlobalAction(GLOBAL_ACTION_DPAD_CENTER);
        }
    }

    private static float clamp(float v, float lo, float hi) {
        return v < lo ? lo : (v > hi ? hi : v);
    }
}
