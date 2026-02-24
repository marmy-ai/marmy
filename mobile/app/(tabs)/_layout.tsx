import { Tabs } from "expo-router";
import { Text } from "react-native";

function TabIcon({ label, focused }: { label: string; focused: boolean }) {
  return (
    <Text style={{ color: focused ? "#7c3aed" : "#666", fontSize: 18 }}>
      {label}
    </Text>
  );
}

export default function TabLayout() {
  return (
    <Tabs
      screenOptions={{
        tabBarStyle: {
          backgroundColor: "#1a1a2e",
          borderTopColor: "#2a2a3e",
        },
        tabBarActiveTintColor: "#7c3aed",
        tabBarInactiveTintColor: "#666",
        headerStyle: { backgroundColor: "#1a1a2e" },
        headerTintColor: "#e0e0e0",
      }}
    >
      <Tabs.Screen
        name="index"
        options={{
          title: "Machines",
          tabBarIcon: ({ focused }) => (
            <TabIcon label="M" focused={focused} />
          ),
        }}
      />
      <Tabs.Screen
        name="sessions"
        options={{
          title: "Sessions",
          tabBarIcon: ({ focused }) => (
            <TabIcon label="S" focused={focused} />
          ),
        }}
      />
      <Tabs.Screen
        name="terminal"
        options={{
          title: "Terminal",
          tabBarIcon: ({ focused }) => (
            <TabIcon label="T" focused={focused} />
          ),
        }}
      />
      <Tabs.Screen
        name="files"
        options={{
          title: "Files",
          tabBarIcon: ({ focused }) => (
            <TabIcon label="F" focused={focused} />
          ),
        }}
      />
    </Tabs>
  );
}
