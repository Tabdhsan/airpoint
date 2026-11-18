package com.bitbyteco.airpoint;

import android.accessibilityservice.AccessibilityService;
import android.graphics.Rect;
import android.os.Bundle;
import android.util.Log;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityNodeInfo.AccessibilityAction;
import android.view.accessibility.AccessibilityWindowInfo;

import java.util.List;

/**
 * Clicks and scrolls by acting on the UI element under the pointer.
 *
 * TV devices usually don't declare a touchscreen, and Android refuses injected touch gestures
 * on such devices, so this is the primary input path. Gestures remain a fallback.
 */
final class NodeInput {
    private final AccessibilityService service;
    /** Presses OK: a real remote key via the phone when available, else an accessibility key. */
    private final Runnable center;
    /** True when the phone can send real remote keys (preferred over accessibility clicks). */
    private final java.util.function.BooleanSupplier realKeys;
    private final android.os.Handler handler = new android.os.Handler(android.os.Looper.getMainLooper());

    NodeInput(AccessibilityService service, Runnable center, java.util.function.BooleanSupplier realKeys) {
        this.service = service;
        this.center = center;
        this.realKeys = realKeys;
    }

    /** Returns true if something under (x, y) accepted the click. */
    boolean click(float x, float y, boolean longClick) {
        AccessibilityNodeInfo target = smallestTarget(x, y, longClick);
        if (target == null) { Log.i(AirPointService.TAG, "nothing to click at " + Math.round(x) + "," + Math.round(y)); return false; }
        final int ix = Math.round(x), iy = Math.round(y);
        boolean clickable = longClick ? target.isLongClickable() : target.isClickable();
        int action = longClick ? AccessibilityNodeInfo.ACTION_LONG_CLICK : AccessibilityNodeInfo.ACTION_CLICK;

        // Fast path: whatever already has focus is under the pointer → behave exactly like the remote.
        if (!longClick) {
            AccessibilityNodeInfo focused = service.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
            Rect fr = new Rect();
            if (focused != null) focused.getBoundsInScreen(fr);
            long area = (long) fr.width() * fr.height();
            if (focused != null && fr.contains(ix, iy) && area < maxTargetArea) {
                if (!realKeys.getAsBoolean() && focused.isClickable() && focused.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
                    log("click focused", focused);
                    return true;
                }
                log("select focused", focused);
                center.run();
                return true;
            }
        }

        // TV apps are built around focus + OK; some (e.g. Jellyfin's user picker) report success for
        // a direct click but ignore it. Use the remote's path when the item can take focus, but only
        // press OK if focus really landed under the pointer (containers can hand focus elsewhere).
        if (target.isFocusable() && !longClick) {
            if (target.isFocused() || target.performAction(AccessibilityNodeInfo.ACTION_FOCUS)) {
                handler.postDelayed(() -> {
                    AccessibilityNodeInfo focused = service.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
                    Rect fr = new Rect();
                    if (focused != null) focused.getBoundsInScreen(fr);
                    if (focused != null && (focused.equals(target) || fr.contains(ix, iy))) {
                        log("focus+select", focused);
                        center.run();
                    } else if (clickable && target.performAction(action)) {
                        log("click (focus went elsewhere)", target);
                    } else {
                        Log.i(AirPointService.TAG, "focus moved away from pointer; not selecting");
                    }
                }, 60);
                return true;
            }
        }
        // Focus refused (common in Compose): try focusing an ancestor that contains the pointer.
        if (!longClick) {
            for (AccessibilityNodeInfo n = target.getParent(); n != null; n = n.getParent()) {
                Rect pr = new Rect();
                n.getBoundsInScreen(pr);
                if ((long) pr.width() * pr.height() >= maxTargetArea) break;
                if (n.isFocusable() && pr.contains(ix, iy) && (n.isFocused() || n.performAction(AccessibilityNodeInfo.ACTION_FOCUS))) {
                    log("focus parent+select", n);
                    handler.postDelayed(() -> center.run(), 60);
                    return true;
                }
            }
        }
        if (clickable && target.performAction(action)) { log("click", target); return true; }
        Log.i(AirPointService.TAG, "click refused by " + target.getClassName());
        return false;
    }

    /**
     * The smallest clickable (or focusable) element containing the point. Full-screen containers
     * often sit above the real buttons in the tree, so "smallest" beats "topmost".
     */
    private AccessibilityNodeInfo smallestTarget(float x, float y, boolean longClick) {
        int ix = Math.round(x), iy = Math.round(y);
        Rect r = new Rect();
        for (AccessibilityWindowInfo w : service.getWindows()) {
            if (w.getType() == AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY) continue;
            w.getBoundsInScreen(r);
            if (!r.contains(ix, iy)) continue;
            AccessibilityNodeInfo root = w.getRoot();
            if (root == null) continue;
            maxTargetArea = (long) r.width() * r.height() / 2;
            AccessibilityNodeInfo[] best = new AccessibilityNodeInfo[1];
            long[] bestArea = { Long.MAX_VALUE };
            collect(root, ix, iy, longClick, best, bestArea, 0);
            if (best[0] != null) return best[0];
        }
        return null;
    }

    private long maxTargetArea = Long.MAX_VALUE;

    private void collect(AccessibilityNodeInfo n, int x, int y, boolean longClick,
                         AccessibilityNodeInfo[] best, long[] bestArea, int depth) {
        if (depth > 60) return;
        Rect r = new Rect();
        n.getBoundsInScreen(r);
        boolean inside = r.contains(x, y);
        // Children can extend outside a parent's bounds in some TV layouts, so keep descending
        // through containers even when the point is outside, but only score nodes that contain it.
        if (inside && n.isVisibleToUser() && n.isEnabled()) {
            boolean candidate = (longClick ? n.isLongClickable() : n.isClickable()) || n.isFocusable();
            long area = (long) r.width() * r.height();
            // Never treat a screen-sized container as the target: clicking empty space must do nothing.
            if (candidate && area > 0 && area < bestArea[0] && area < maxTargetArea) {
                best[0] = n;
                bestArea[0] = area;
            }
        }
        if (!inside && r.width() > 0 && r.height() > 0) return;
        for (int i = 0; i < n.getChildCount(); i++) {
            AccessibilityNodeInfo c = n.getChild(i);
            if (c != null) collect(c, x, y, longClick, best, bestArea, depth + 1);
        }
    }

    /** Moves focus to the element under the pointer without selecting it (hover highlight). */
    void focus(float x, float y) {
        AccessibilityNodeInfo hit = nodeAt(x, y);
        for (AccessibilityNodeInfo n = hit; n != null; n = n.getParent()) {
            if (n.isFocusable()) {
                if (!n.isFocused()) n.performAction(AccessibilityNodeInfo.ACTION_FOCUS);
                return;
            }
        }
    }

    /**
     * Scrolls the nearest scrollable container under (x, y) one step in the direction content
     * should move to reveal what is beyond it. dirX/dirY are -1, 0 or 1 (finger direction).
     */
    boolean scroll(float x, float y, int dirX, int dirY) {
        AccessibilityNodeInfo hit = nodeAt(x, y);
        // Finger moving up reveals content below → scroll down.
        AccessibilityAction wanted = dirY < 0 ? AccessibilityAction.ACTION_SCROLL_DOWN
                : dirY > 0 ? AccessibilityAction.ACTION_SCROLL_UP
                : dirX < 0 ? AccessibilityAction.ACTION_SCROLL_RIGHT
                : AccessibilityAction.ACTION_SCROLL_LEFT;
        int generic = (dirY < 0 || dirX < 0) ? AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                : AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD;
        boolean horizontal = dirX != 0;
        for (AccessibilityNodeInfo n = hit; n != null; n = n.getParent()) {
            if (!n.isScrollable()) continue;
            if (has(n, wanted) && n.performAction(wanted.getId())) { log("scroll", n); return true; }
            // A generic forward/backward only applies if the container has no directional actions
            // for the other axis (avoids scrolling a vertical page when swiping sideways).
            boolean hasDirectional = has(n, AccessibilityAction.ACTION_SCROLL_DOWN) || has(n, AccessibilityAction.ACTION_SCROLL_UP)
                    || has(n, AccessibilityAction.ACTION_SCROLL_LEFT) || has(n, AccessibilityAction.ACTION_SCROLL_RIGHT);
            if (!hasDirectional && n.performAction(generic)) { log("scroll generic h=" + horizontal, n); return true; }
        }
        // Fall back to D-pad from the item under the pointer, which TV apps always understand.
        for (AccessibilityNodeInfo n = hit; n != null; n = n.getParent()) {
            if (n.isFocusable()) {
                if (!n.isFocused()) n.performAction(AccessibilityNodeInfo.ACTION_FOCUS);
                break;
            }
        }
        int dpad = dirY < 0 ? AccessibilityService.GLOBAL_ACTION_DPAD_DOWN
                : dirY > 0 ? AccessibilityService.GLOBAL_ACTION_DPAD_UP
                : dirX < 0 ? AccessibilityService.GLOBAL_ACTION_DPAD_RIGHT
                : AccessibilityService.GLOBAL_ACTION_DPAD_LEFT;
        return service.performGlobalAction(dpad);
    }

    private static boolean has(AccessibilityNodeInfo n, AccessibilityAction a) {
        return n.getActionList().contains(a);
    }

    /** Deepest node under the point in each window containing it, topmost window first. */
    private java.util.ArrayList<AccessibilityNodeInfo> hitsAt(float x, float y) {
        int ix = Math.round(x), iy = Math.round(y);
        java.util.ArrayList<AccessibilityNodeInfo> hits = new java.util.ArrayList<>();
        Rect r = new Rect();
        for (AccessibilityWindowInfo w : service.getWindows()) {
            if (w.getType() == AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY) continue;
            w.getBoundsInScreen(r);
            if (!r.contains(ix, iy)) continue;
            AccessibilityNodeInfo root = w.getRoot();
            if (root == null) continue;
            root.refresh();
            AccessibilityNodeInfo hit = deepest(root, ix, iy);
            if (hit != null) hits.add(hit);
        }
        if (hits.isEmpty()) {
            AccessibilityNodeInfo root = service.getRootInActiveWindow();
            if (root != null) {
                AccessibilityNodeInfo hit = deepest(root, ix, iy);
                if (hit != null) hits.add(hit);
            }
        }
        return hits;
    }

    private AccessibilityNodeInfo nodeAt(float x, float y) {
        java.util.ArrayList<AccessibilityNodeInfo> hits = hitsAt(x, y);
        return hits.isEmpty() ? null : hits.get(0);
    }

    private void dumpWindows(float x, float y) {
        Rect r = new Rect();
        StringBuilder sb = new StringBuilder("no target at " + Math.round(x) + "," + Math.round(y) + "; windows:");
        for (AccessibilityWindowInfo w : service.getWindows()) {
            w.getBoundsInScreen(r);
            AccessibilityNodeInfo root = w.getRoot();
            sb.append("\n  type=").append(w.getType()).append(" layer=").append(w.getLayer())
              .append(" ").append(r.toShortString()).append(" title=").append(w.getTitle())
              .append(" root=").append(root == null ? "null" : root.getPackageName() + "/" + root.getChildCount());
            if (root != null) {
                AccessibilityNodeInfo hit = deepest(root, Math.round(x), Math.round(y));
                if (hit != null) {
                    sb.append(" hit=").append(hit.getClassName()).append(" clickable=").append(hit.isClickable())
                      .append(" focusable=").append(hit.isFocusable());
                    AccessibilityNodeInfo p = hit.getParent(); int d = 0;
                    while (p != null && d < 6) { sb.append(" <").append(p.getClassName()).append(p.isClickable() ? "*" : "").append(p.isFocusable() ? "f" : ""); p = p.getParent(); d++; }
                }
            }
        }
        Log.i(AirPointService.TAG, sb.toString());
    }

    private static AccessibilityNodeInfo deepest(AccessibilityNodeInfo node, int x, int y) {
        Rect r = new Rect();
        node.getBoundsInScreen(r);
        if (!node.isVisibleToUser() || !r.contains(x, y)) return null;
        // Later children are drawn on top; check them first.
        for (int i = node.getChildCount() - 1; i >= 0; i--) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child == null) continue;
            AccessibilityNodeInfo hit = deepest(child, x, y);
            if (hit != null) return hit;
        }
        return node;
    }

    private static void log(String what, AccessibilityNodeInfo n) {
        Rect r = new Rect();
        n.getBoundsInScreen(r);
        Log.i(AirPointService.TAG, what + " on " + n.getClassName() + " \"" + (n.getText() != null ? n.getText()
                : n.getContentDescription()) + "\" " + r.toShortString());
    }
}
