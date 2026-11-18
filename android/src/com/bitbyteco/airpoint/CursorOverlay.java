package com.bitbyteco.airpoint;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.view.View;
import android.widget.FrameLayout;

/** Full-screen, non-touchable layer holding a small arrow that is moved with translations. */
class CursorOverlay extends FrameLayout {
    private final Arrow arrow;
    private final int size;

    CursorOverlay(Context context) {
        super(context);
        float d = context.getResources().getDisplayMetrics().density;
        size = Math.round(36 * d);
        arrow = new Arrow(context, d);
        addView(arrow, new LayoutParams(size, size));
    }

    void moveCursor(float x, float y) {
        arrow.setTranslationX(x - arrow.tipX());
        arrow.setTranslationY(y - arrow.tipY());
    }

    void setCursorVisible(boolean visible) {
        if (visible) {
            if (arrow.getVisibility() != VISIBLE) {
                arrow.animate().cancel();
                arrow.setAlpha(1f);
                arrow.setVisibility(VISIBLE);
            }
        } else if (arrow.getVisibility() == VISIBLE) {
            arrow.animate().alpha(0f).setDuration(250).withEndAction(() -> arrow.setVisibility(INVISIBLE));
        }
    }

    boolean isCursorVisible() {
        return arrow.getVisibility() == VISIBLE && arrow.getAlpha() > 0.5f;
    }

    void pulse() {
        arrow.setScaleX(0.8f);
        arrow.setScaleY(0.8f);
        arrow.animate().scaleX(1f).scaleY(1f).setDuration(150);
    }

    private static class Arrow extends View {
        private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint stroke = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Path path = new Path();
        private final float pad;

        Arrow(Context c, float d) {
            super(c);
            pad = 3 * d;
            fill.setColor(0xFFFFFFFF);
            fill.setStyle(Paint.Style.FILL);
            fill.setShadowLayer(4 * d, 0, d, 0x80000000);
            stroke.setColor(0xFF000000);
            stroke.setStyle(Paint.Style.STROKE);
            stroke.setStrokeWidth(1.6f * d);
            stroke.setStrokeJoin(Paint.Join.ROUND);
            setLayerType(LAYER_TYPE_SOFTWARE, null); // needed for the shadow
            setPivotX(pad);
            setPivotY(pad);
        }

        float tipX() { return pad; }
        float tipY() { return pad; }

        @Override
        protected void onSizeChanged(int w, int h, int ow, int oh) {
            float s = (w - 2 * pad) / 28f;
            path.reset();
            path.moveTo(pad, pad);
            path.lineTo(pad, pad + 24 * s);
            path.lineTo(pad + 6 * s, pad + 18.5f * s);
            path.lineTo(pad + 10.5f * s, pad + 27.5f * s);
            path.lineTo(pad + 14.5f * s, pad + 25.5f * s);
            path.lineTo(pad + 10f * s, pad + 17f * s);
            path.lineTo(pad + 18f * s, pad + 17f * s);
            path.close();
        }

        @Override
        protected void onDraw(Canvas canvas) {
            canvas.drawPath(path, fill);
            canvas.drawPath(path, stroke);
        }
    }
}
