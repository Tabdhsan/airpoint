package com.bitbyteco.airpoint;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.Gravity;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Status screen: shows whether the service is on and offers a shortcut to accessibility settings. */
public class MainActivity extends Activity {
    private TextView text;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable refresh = new Runnable() {
        @Override public void run() {
            update();
            handler.postDelayed(this, 1000);
        }
    };

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER);
        root.setPadding(96, 96, 96, 96);
        root.setBackgroundColor(0xFF111827);

        TextView title = new TextView(this);
        title.setText("AirPoint");
        title.setTextSize(36);
        title.setTextColor(0xFFFFFFFF);
        root.addView(title);

        text = new TextView(this);
        text.setTextSize(18);
        text.setTextColor(0xFFD1D5DB);
        text.setPadding(0, 32, 0, 32);
        root.addView(text);

        Button settings = new Button(this);
        settings.setText("Open accessibility settings");
        settings.setOnClickListener(v -> startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)));
        root.addView(settings);

        setContentView(root);
    }

    @Override protected void onResume() { super.onResume(); handler.post(refresh); }
    @Override protected void onPause() { handler.removeCallbacks(refresh); super.onPause(); }

    private void update() {
        String enabled = Settings.Secure.getString(getContentResolver(), Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
        boolean on = enabled != null && enabled.contains(getPackageName() + "/");
        long age = System.currentTimeMillis() - AirPointService.lastPacketAt;
        String last = AirPointService.lastPacketAt == 0 ? "never"
                : (age < 2000 ? "just now" : (age / 1000) + " s ago") + " from " + AirPointService.lastSender;
        text.setText("Service: " + (on ? "on" : "off — enable AirPoint in accessibility settings")
                + "\nStatus: " + AirPointService.status
                + "\nLast phone packet: " + last
                + "\n\nOpen the AirPoint app on your iPhone on the same Wi-Fi network.");
    }
}
