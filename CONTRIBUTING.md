# Contributing to Marmy

Thanks for your interest in contributing! This guide will help you get started.

## How to Contribute

1. **Fork** the repository
2. **Create a branch** from `main` for your change (`git checkout -b my-feature`)
3. **Make your changes** and test them locally
4. **Commit** with a clear message describing what and why
5. **Push** your branch and open a **Pull Request** against `main`

Please keep PRs focused — one feature or fix per PR. If your change is large, consider opening an issue first to discuss the approach.

## Development Setup

### Agent (Rust daemon)

```bash
cd agent
cargo build              # Debug build
cargo run -- serve       # Run locally
cargo test               # Run tests

# Debug logging
RUST_LOG=marmy_agent=debug cargo run -- serve
```

**Requires:** Rust (latest stable), tmux 3.2+

### Mobile App (React Native / Expo)

```bash
cd mobile
npm install
npx expo start           # Start dev server
npx expo start --clear   # Clear cache and start
```

To build for iOS via Xcode:

```bash
npx expo prebuild --platform ios
cd ios && rm -rf Pods Podfile.lock && pod install && cd ..
open ios/marmy.xcworkspace
```

Then in Xcode: select your signing team, set build config to Release, and Cmd+R.

**Requires:** Node.js 18+, Expo CLI, Xcode (for iOS builds)

### Website (Astro)

```bash
cd website
npm install
npm run dev              # Start dev server
npm run build            # Production build
```

## Coding Standards

- **Rust**: Follow standard Rust conventions. Use `cargo fmt` before committing and ensure `cargo clippy` passes without warnings.
- **TypeScript**: Use TypeScript for all JS code. Prefer explicit types over `any`.
- **Commits**: Write clear, concise commit messages. Use imperative mood ("Add feature" not "Added feature").
- **No secrets**: Never commit API keys, tokens, or credentials. Use environment variables and `.env` files (which are gitignored).

## Reporting Issues

- Use [GitHub Issues](https://github.com/marmy-ai/marmy/issues) to report bugs or request features
- Include steps to reproduce for bugs
- Include your OS, Rust version, Node version, and tmux version where relevant
- Check existing issues before opening a new one

## Project Structure

```
marmy/
├── agent/       # Rust daemon — tmux control mode, REST API, WebSocket
├── mobile/      # React Native (Expo) mobile app
├── macos/       # macOS menu bar app (Swift)
├── website/     # Documentation website (Astro)
└── scripts/     # Build and utility scripts
```

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
