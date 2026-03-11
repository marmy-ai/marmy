import { useEffect } from "react";
import { Stack } from "expo-router";
import { useRouter } from "expo-router";
import { StatusBar } from "expo-status-bar";
import { useConnectionStore } from "../src/stores/connectionStore";
import { useSessionStore } from "../src/stores/sessionStore";
import { theme } from "../src/theme";
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
        router.navigate("/terminal");
      }
    });
    return () => subscription.remove();
  }, []);

  return (
    <>
      <StatusBar style="light" />
      <Stack
        screenOptions={{
          headerStyle: { backgroundColor: theme.headerBg },
          headerTintColor: theme.headerText,
          contentStyle: { backgroundColor: theme.bgDeep },
        }}
      >
        <Stack.Screen name="index" options={{ title: "Machines", headerShown: false }} />
        <Stack.Screen name="workers" options={{ title: "Workers", headerBackTitle: "Machines" }} />
        <Stack.Screen name="terminal" />
        <Stack.Screen name="files" options={{ title: "Files" }} />
      </Stack>
    </>
  );
}
