import * as Notifications from "expo-notifications";
import { Platform } from "react-native";
import type { MarmyApi } from "./api";

// Configure how notifications appear when app is in foreground
Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowAlert: true,
    shouldPlaySound: true,
    shouldSetBadge: false,
    shouldShowBanner: true,
    shouldShowList: true,
  }),
});

export async function registerForPushNotifications(
  api: MarmyApi
): Promise<string | null> {
  try {
    const { status: existingStatus } =
      await Notifications.getPermissionsAsync();
    let finalStatus = existingStatus;

    if (existingStatus !== "granted") {
      const { status } = await Notifications.requestPermissionsAsync();
      finalStatus = status;
    }

    if (finalStatus !== "granted") {
      console.warn("[notifications] permission not granted:", finalStatus);
      return null;
    }

    if (Platform.OS === "android") {
      await Notifications.setNotificationChannelAsync("default", {
        name: "default",
        importance: Notifications.AndroidImportance.HIGH,
      });
    }

    // Get raw APNs/FCM device token — no Expo account needed
    const tokenData = await Notifications.getDevicePushTokenAsync();
    const token = tokenData.data;
    console.log("[notifications] got device push token:", token);

    // Register with the agent
    await api.registerPushToken(token);
    console.log("[notifications] registered token with agent");

    return token;
  } catch (e) {
    console.error("[notifications] registration failed:", e);
    return null;
  }
}

export async function unregisterPushNotifications(
  api: MarmyApi,
  token: string
): Promise<void> {
  await api.unregisterPushToken(token);
}

export type NotificationTapData = {
  pane_id?: string;
  session_name?: string;
};

export function addNotificationResponseListener(
  handler: (data: NotificationTapData) => void
): Notifications.EventSubscription {
  return Notifications.addNotificationResponseReceivedListener((response) => {
    const data = response.notification.request.content
      .data as NotificationTapData;
    handler(data);
  });
}
