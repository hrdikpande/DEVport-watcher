# Contributing

Thanks for contributing to Ports.

## Development requirements

- macOS 14 or later
- Swift 5.10 or later
- Xcode or the Apple command-line developer tools

## Workflow

1. Open an issue for significant behavior or UX changes.
2. Keep changes focused and preserve the safety model.
3. Add or update fixture-based tests for scanner, classifier, and process-control behavior.
4. Run:

   ```sh
   swift build
   swift test
   ```

5. Update `CHANGELOG.md` for user-visible changes.

Never weaken process-identity, ownership, confirmation, timeout, or argument-validation guards.
