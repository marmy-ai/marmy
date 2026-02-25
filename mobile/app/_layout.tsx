import { useEffect } from "react";
import { Stack } from "expo-router";
import { StatusBar } from "expo-status-bar";
import { useConnectionStore } from "../src/stores/connectionStore";

export default function RootLayout() {
  const hydrate = useConnectionStore((s) => s.hydrate);

  useEffect(() => {
    hydrate();
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
