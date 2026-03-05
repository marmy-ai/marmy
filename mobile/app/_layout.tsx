import { useEffect } from "react";
import { Stack } from "expo-router";
import { useRouter } from "expo-router";
import { StatusBar } from "expo-status-bar";
import { useConnectionStore } from "../src/stores/connectionStore";
import { useSessionStore } from "../src/stores/sessionStore";
import { addNotificationResponseListener } from "../src/services/notifications";

export default function RootLayout() {
  const hydrate = useConnectionStore((s) => s.hydrate);
  const setActivePane = useSessionStore((s) => s.setActivePane);
  const router = useRouter();

  useEffect(() => {
    hydrate();
  }, []);

  // Handle notification taps — navigate to the relevant pane
  useEffect(() => {
    const subscription = addNotificationResponseListener((data) => {
      if (data.pane_id) {
        setActivePane(data.pane_id);
        router.navigate("/(tabs)/terminal");
      }
    });
    return () => subscription.remove();
  }, []);

  return (
    <>
      <StatusBar style="light" />
      <Stack
        screenOptions={{
          headerStyle: { backgroundColor: "#1a1a2e" },
          headerTintColor: "#e0e0e0",
          contentStyle: { backgroundColor: "#0f0f1a" },
        }}
      >
        <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
      </Stack>
    </>
  );
}
