import React, { useRef, useCallback, useEffect } from "react";
import { View, StyleSheet } from "react-native";
import { WebView } from "react-native-webview";

interface TerminalViewProps {
  /** Called when the terminal is ready to receive data. */
  onReady?: () => void;
  /** Called when the user types in the terminal. */
  onInput?: (data: string) => void;
  /** Called when the terminal reports its dimensions. */
  onResize?: (cols: number, rows: number) => void;
  /** Reference to imperatively write data to the terminal. */
  terminalRef?: React.MutableRefObject<TerminalHandle | null>;
}

export interface TerminalHandle {
  write: (data: string) => void;
  clear: () => void;
}

const TERMINAL_HTML = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.min.css">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body { width: 100%; height: 100%; overflow: hidden; background: #0f0f1a; }
    #terminal { width: 100%; height: 100%; }
    .xterm { padding: 4px; }
  </style>
</head>
<body>
  <div id="terminal"></div>
  <script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/@xterm/addon-web-links@0.11.0/lib/addon-web-links.min.js"></script>
  <script>
    const term = new Terminal({
      cursorBlink: true,
      fontSize: 13,
      fontFamily: 'Menlo, Monaco, "Courier New", monospace',
      theme: {
        background: '#0f0f1a',
        foreground: '#e0e0e0',
        cursor: '#7c3aed',
        selectionBackground: 'rgba(124, 58, 237, 0.3)',
        black: '#1a1a2e',
        red: '#ff6b6b',
        green: '#51cf66',
        yellow: '#ffd43b',
        blue: '#339af0',
        magenta: '#cc5de8',
        cyan: '#22b8cf',
        white: '#e0e0e0',
        brightBlack: '#555',
        brightRed: '#ff8787',
        brightGreen: '#69db7c',
        brightYellow: '#ffe066',
        brightBlue: '#5c7cfa',
        brightMagenta: '#da77f2',
        brightCyan: '#3bc9db',
        brightWhite: '#fff',
      },
      allowProposedApi: true,
    });

    const fitAddon = new FitAddon.FitAddon();
    term.loadAddon(fitAddon);
    term.loadAddon(new WebLinksAddon.WebLinksAddon());

    term.open(document.getElementById('terminal'));
    fitAddon.fit();

    // Report dimensions on resize
    function reportSize() {
      fitAddon.fit();
      window.ReactNativeWebView.postMessage(JSON.stringify({
        type: 'resize',
        cols: term.cols,
        rows: term.rows,
      }));
    }

    window.addEventListener('resize', reportSize);
    new ResizeObserver(reportSize).observe(document.getElementById('terminal'));

    // Forward user input to React Native
    term.onData(function(data) {
      window.ReactNativeWebView.postMessage(JSON.stringify({
        type: 'input',
        data: data,
      }));
    });

    // Signal ready
    window.ReactNativeWebView.postMessage(JSON.stringify({ type: 'ready' }));
    reportSize();
  </script>
</body>
</html>`;

export default function TerminalView({
  onReady,
  onInput,
  onResize,
  terminalRef,
}: TerminalViewProps) {
  const webViewRef = useRef<WebView>(null);

  // Expose write/clear to parent
  useEffect(() => {
    if (terminalRef) {
      terminalRef.current = {
        write: (data: string) => {
          const escaped = JSON.stringify(data);
          webViewRef.current?.injectJavaScript(
            `term.write(${escaped}); true;`
          );
        },
        clear: () => {
          webViewRef.current?.injectJavaScript(`term.clear(); true;`);
        },
      };
    }
  }, [terminalRef]);

  const handleMessage = useCallback(
    (event: { nativeEvent: { data: string } }) => {
      try {
        const msg = JSON.parse(event.nativeEvent.data);
        switch (msg.type) {
          case "ready":
            onReady?.();
            break;
          case "input":
            onInput?.(msg.data);
            break;
          case "resize":
            onResize?.(msg.cols, msg.rows);
            break;
        }
      } catch {
        // ignore parse errors
      }
    },
    [onReady, onInput, onResize]
  );

  return (
    <View style={styles.container}>
      <WebView
        ref={webViewRef}
        source={{ html: TERMINAL_HTML }}
        style={styles.webview}
        onMessage={handleMessage}
        javaScriptEnabled
        domStorageEnabled
        scrollEnabled={false}
        bounces={false}
        overScrollMode="never"
        allowsInlineMediaPlayback
        mixedContentMode="always"
        originWhitelist={["*"]}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#0f0f1a" },
  webview: { flex: 1, backgroundColor: "transparent" },
});
